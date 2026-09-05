/* cmacs-gowl.c — Gowl Wayland compositor integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Links against libgowl.  Instantiates GowlCompositor and exposes
 * operations as DEFUNs — keybinds, rules, layout, monitor, focus,
 * tags, session, client state, hooks, and GObject accessors for
 * full runtime GI control.
 *
 * Phase 7b: full window manager control from C/GI — no elisp required.
 */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include "lisp.h"
#include "xwidget.h"
#include <epaths.h>
#include "cmacs-gowl.h"
#include "cmacs-gobject.h"
#include "cmacs-eval-dispatch.h"
#include <gowl.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wayland-client-core.h>
#include <wlr/backend.h>
#include <wlr/backend/wayland.h>
#include <wlr/types/wlr_output.h>
#include "keyboard-shortcuts-inhibit-v1-client.h"

#ifdef HAVE_PGTK
#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#include "pgtkterm.h"
#include "frame.h"
#include "window.h"
#endif

#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_seat.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <wlr/types/wlr_buffer.h>
#include <drm_fourcc.h>
#include <cairo.h>
#include <pthread.h>

/* Persistent compositor instance.
   NOT static — cmacs-eval-dispatch.c accesses this for gowl dispatch. */
GowlCompositor *cmacs_gowl_compositor = NULL;

GowlCompositor *
cmacs_gowl_get_compositor (void)
{
  return cmacs_gowl_compositor;
}

/* ── Keybind action name <-> value ────────────────────────────────────
 *
 * gowl registers GowlAction as a GEnum whose nicks are exactly the
 * names a config uses, so both directions come out of that one table
 * instead of a switch that has to be extended in lockstep with gowl.
 * Adding an action upstream now reaches every cmacs surface at once:
 * `gowl-add-keybind', the D-Bus/MCP dispatch, and the cheatsheet.  */

gboolean
cmacs_gowl_action_from_name (const gchar *name, gint *out_action)
{
  GEnumClass *klass;
  GEnumValue *val;
  g_autofree gchar *norm = NULL;

  if (name == NULL || out_action == NULL)
    return false;

  /* gowl's YAML parser normalises underscores to hyphens; do the same
     so a config and an Elisp call spell an action identically. */
  norm = g_strdup (name);
  g_strdelimit (norm, "_", '-');

  klass = (GEnumClass *) g_type_class_ref (GOWL_TYPE_ACTION);
  val = g_enum_get_value_by_nick (klass, norm);
  if (val != NULL)
    *out_action = val->value;
  g_type_class_unref (klass);

  return val != NULL;
}

const gchar *
cmacs_gowl_action_to_name (gint action)
{
  GEnumClass *klass;
  GEnumValue *val;
  const gchar *nick = NULL;

  /* g_type_class_ref keeps the class alive for the process (GLib caches
     enum classes), so the nick stays valid after the unref below. */
  klass = (GEnumClass *) g_type_class_ref (GOWL_TYPE_ACTION);
  val = g_enum_get_value (klass, action);
  if (val != NULL)
    nick = val->value_nick;
  g_type_class_unref (klass);

  return nick;
}

/* TRUE while a keyboard-interactive layer-shell surface -- a launcher
   such as wofi, an on-screen keyboard -- holds an exclusive keyboard
   grab in the compositor.

   Every cmacs path that moves seat keyboard focus does so by calling
   wlr_seat_keyboard_notify_enter() directly rather than going through
   gowl_compositor_focus_client(): embedded clients are deliberately
   invisible to the compositor's focus stack, so the guards inside
   focus_client() do not apply.  That makes this check the ONLY thing
   standing between an embedded-focus move and a stolen launcher, and
   it must be consulted before every one of them.

   The failure it prevents: wofi maps, arrangelayers grants it the
   keyboard, and milliseconds later a focus-follows-mouse enter, a
   click, or `post-command-hook' -> `gowl-return-focus-to-embed' takes
   the keyboard straight back.  wofi stays drawn, on top, covering the
   whole output -- and completely deaf.  The user can neither type into
   it, nor dismiss it, nor see that anything else is responding.
   Reported by Ben Doty, 2026-08-08.

   The compositor derives this from live surface state (mapped,
   keyboard_interactive, layer), so it releases by itself the moment
   the launcher goes away -- it cannot wedge focus permanently.
   `test/cmacs/cmacs-gowl-tests.el' asserts that no
   wlr_seat_keyboard_notify_enter call site in this file skips it.  */
static gboolean
cmacs_gowl_layer_owns_keyboard (void)
{
  return cmacs_gowl_compositor != NULL
         && gowl_compositor_has_exclusive_keyboard_layer (
              cmacs_gowl_compositor);
}

/* Shared-object globals that user-written C configs declare as
   `extern GowlCompositor *gowl_compositor;` / `extern GowlConfig
   *gowl_config;`.  Standalone gowl defines them in its main.c; when
   embedded in cmacs we must provide matching symbols so the
   `g_module_open()` of a compiled C config can resolve them against
   the running process.  Values are populated at `--gowl` init time
   in src/emacs.c right before the C config is loaded (if any). */
GowlCompositor *gowl_compositor = NULL;
GowlConfig     *gowl_config     = NULL;

/* Mutex guarding wlroots seat, scene graph, and wl_display client-
   queue state.  The dispatch thread holds it during
   wl_event_loop_dispatch(); GDK event handlers and DEFUNs acquire
   it before calling wlroots functions.

   Recursive so a DEFUN that mutates compositor state under the
   mutex can safely emit a GObject signal whose handlers in turn
   call back through another DEFUN (e.g. a workspace-switch DEFUN
   emits `workspace-switched', which fires the ext-workspace-v1
   bridge which also wants the mutex).  wlroots itself uses no
   locking, but wayland-server's per-resource post_event path
   assumes single-threaded access; a recursive mutex gives the
   same guarantee without requiring every signal handler to know
   whether it was invoked from the dispatch tick or a main-thread
   DEFUN.

   Wave 2 (GSource-on-cmacs_context) deleted this and lost gtk_init:
   GDK calls wl_display_roundtrip_queue() long before Emacs reaches
   wait_reading_process_output, so the GSource never fires and the
   roundtrip blocks forever.  The dispatch thread is load-bearing
   during compositor bootstrap even if the GLib-loop integration
   otherwise duplicates its job; keep it. */
static pthread_mutex_t cmacs_gowl_mutex;

static pthread_once_t cmacs_gowl_mutex_once = PTHREAD_ONCE_INIT;

static void
cmacs_gowl_mutex_init (void)
{
  pthread_mutexattr_t attr;

  pthread_mutexattr_init (&attr);
  pthread_mutexattr_settype (&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init (&cmacs_gowl_mutex, &attr);
  pthread_mutexattr_destroy (&attr);
}

/* Idempotent accessor; callers use pthread_mutex_lock/unlock on
   &cmacs_gowl_mutex directly afterwards.  Called from
   cmacs_gowl_start_thread and from every DEFUN that locks. */
static inline void
cmacs_gowl_ensure_mutex (void)
{
  pthread_once (&cmacs_gowl_mutex_once, cmacs_gowl_mutex_init);
}

/* Public wrappers around the compositor dispatch mutex so other cmacs
   subsystems (e.g. cmacs-screensaver pushing raw frames into the scene
   graph) can serialise against the gowl dispatch thread, which mutates and
   renders the scene under this same (recursive) lock. */
void
cmacs_gowl_lock (void)
{
  cmacs_gowl_ensure_mutex ();
  pthread_mutex_lock (&cmacs_gowl_mutex);
}

void
cmacs_gowl_unlock (void)
{
  pthread_mutex_unlock (&cmacs_gowl_mutex);
}

/* Clipboard sync: signal handler ID (0 = not watching) */
static gulong cmacs_clipboard_handler_id = 0;
static gulong cmacs_psel_handler_id = 0;

/* ── Embed view (GTK widget inside Emacs frame) ────────────────────────
 *
 * Each embedded client gets a GtkDrawingArea added to the Emacs frame's
 * GtkFixed container.  The draw callback reads pixels from the client's
 * wlr_buffer via wlr_buffer_begin_data_ptr_access() (CPU-side, no EGL)
 * and paints them with Cairo.  A wl_listener on surface->events.commit
 * queues a redraw when the client renders a new frame.
 *
 * Input: mouse/keyboard events on the GtkDrawingArea are forwarded to
 * the Wayland client via the compositor's wlr_seat.
 */

struct gowl_embed_view
{
  GtkWidget *widget;            /* GtkDrawingArea in the Emacs frame */
  GowlClient *client;          /* The embedded Wayland client */
  struct frame *emacs_frame;   /* Emacs frame containing the widget */
  struct wl_listener commit;   /* wlr_surface commit listener */
  struct wl_listener destroy;  /* wlr_surface destroy listener */
  gboolean xwidget_managed;   /* TRUE if widget is owned by xwidget system */
  unsigned char *pixel_buf;    /* Pixel readback buffer */
  size_t pixel_buf_size;       /* Allocated size of pixel_buf */
  cairo_surface_t *cr_surface; /* Cairo surface wrapping pixel_buf */
  int tex_w, tex_h;            /* Last captured texture dimensions */
  int view_w, view_h;          /* Widget display size */
  gboolean dirty;              /* New frame available */
  guint idle_id;               /* Pending idle capture source, or 0 */
};

static GHashTable *embed_views = NULL; /* GowlClient* -> gowl_embed_view* */

/* The direct gowl-embed view that currently owns keyboard focus
   (click-to-focus model), or NULL.  Prevents xwidget focus-follows-mouse
   leave events from clearing compositor keyboard focus.  */
static struct gowl_embed_view *direct_embed_kb_owner;

/* ── Prefix-key focus redirect state ──────────────────────────────────
 *
 * Set by cmacs_gowl_key_intercept() when a prefix key is detected and
 * we push a focus redirect on the seat.  Cleared by the matching
 * `gowl-return-focus-to-embed` DEFUN (called from Elisp
 * post-command-hook).  Lives at file scope because push/pop happen
 * from different call sites: push is in the compositor dispatch
 * callback, pop comes from Elisp after the command chain completes.
 *
 * At most one redirect is active at a time — nested prefix sequences
 * short-circuit because we only push when the embed is focused, and
 * after a successful push Emacs holds focus.
 *
 * cmacs_gowl_redirect_is_sticky distinguishes two redirect modes:
 *   - prefix-key (C-x etc): Emacs's post-command-hook pops after the
 *     command completes.  Auto-pop.
 *   - sticky (plain ESC, hardcoded): Emacs keeps focus until the
 *     user explicitly returns (click on embed, or calls
 *     `gowl-return-focus-to-embed').  No auto-pop. */
static GowlFocusToken *cmacs_gowl_active_focus_token = NULL;
static gboolean        cmacs_gowl_redirect_is_sticky  = FALSE;

/* ── Pending embed counter (for client-map callback) ─────────────────
 * Incremented by gowl-embed-expect-client, decremented by the
 * client-map callback.  When > 0, newly mapped clients that weren't
 * caught by prefloat PID matching are force-embedded. */
static int cmacs_embed_pending_count = 0;

static void
gowl_embed_view_capture (struct gowl_embed_view *view)
{
  struct wlr_surface *surface;
  struct wlr_buffer *buffer;
  void *data;
  uint32_t fmt;
  size_t src_stride, needed;
  int tw, th;

  if (view->client == NULL)
    return;

  surface = gowl_client_get_wlr_surface (view->client);
  if (surface == NULL || surface->buffer == NULL)
    return;

  buffer = &surface->buffer->base;
  tw = buffer->width;
  th = buffer->height;

  /* Access pixel data directly from the buffer — no EGL needed.
     This is safe to call from the GTK main thread because it uses
     CPU-side access (SHM direct pointer or DMA-BUF CPU map),
     avoiding the EGL context which belongs to the compositor thread. */
  if (!wlr_buffer_begin_data_ptr_access (buffer,
                                         WLR_BUFFER_DATA_PTR_ACCESS_READ,
                                         &data, &fmt, &src_stride))
    return;

  needed = src_stride * (size_t) th;

  if (needed > view->pixel_buf_size)
    {
      g_free (view->pixel_buf);
      view->pixel_buf = g_malloc (needed);
      view->pixel_buf_size = needed;
    }

  memcpy (view->pixel_buf, data, needed);
  wlr_buffer_end_data_ptr_access (buffer);

  /* Recreate Cairo surface if dimensions changed. */
  if (view->cr_surface != NULL
      && (view->tex_w != tw || view->tex_h != th))
    {
      cairo_surface_destroy (view->cr_surface);
      view->cr_surface = NULL;
    }

  if (view->cr_surface == NULL)
    view->cr_surface = cairo_image_surface_create_for_data (
      view->pixel_buf, CAIRO_FORMAT_ARGB32, tw, th, (int) src_stride);
  else
    cairo_surface_mark_dirty (view->cr_surface);

  view->tex_w = tw;
  view->tex_h = th;
}

static gboolean
gowl_embed_view_draw (GtkWidget *widget, cairo_t *cr, gpointer data)
{
  struct gowl_embed_view *view = data;
  (void) widget;

  /* Pixels were already captured in the commit callback (which runs
     during Wayland event processing, when the compositor's EGL context
     is idle).  We just paint the stored surface here. */
  if (view->cr_surface == NULL)
    return FALSE;

  /* Scale texture to fill the widget area. */
  if (view->tex_w > 0 && view->tex_h > 0
      && view->view_w > 0 && view->view_h > 0)
    {
      double sx = (double) view->view_w / (double) view->tex_w;
      double sy = (double) view->view_h / (double) view->tex_h;
      cairo_scale (cr, sx, sy);
    }

  cairo_set_source_surface (cr, view->cr_surface, 0, 0);
  cairo_set_operator (cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint (cr);

  return TRUE;
}

static gboolean
gowl_embed_view_idle_capture (gpointer data)
{
  struct gowl_embed_view *view = data;

  view->idle_id = 0;
  if (view->client == NULL || !view->dirty || view->widget == NULL)
    return G_SOURCE_REMOVE;

  /* Read pixels via wlr_buffer CPU access (no EGL needed).
     Safe on the GTK main thread — avoids the compositor's EGL context. */
  gowl_embed_view_capture (view);
  view->dirty = FALSE;
  gtk_widget_queue_draw (view->widget);
  return G_SOURCE_REMOVE;
}

static void
gowl_embed_view_on_commit (struct wl_listener *listener, void *data)
{
  struct gowl_embed_view *view =
    wl_container_of (listener, view, commit);
  (void) data;

  view->dirty = TRUE;
  /* Schedule ONE capture per idle cycle.  Multiple client commits
     are batched — only the latest frame is captured.  Idle priority
     ensures the compositor finishes its output render first. */
  if (view->idle_id == 0)
    view->idle_id = g_idle_add (gowl_embed_view_idle_capture, view);
}

static void gowl_embed_view_free (struct gowl_embed_view *view);

/* Main-thread cleanup after the Wayland surface is destroyed.
   The dispatch-thread handler (on_surface_destroy) already removed
   the wl_listeners; this finishes tearing down the GTK side.  */
static gboolean
gowl_embed_view_destroy_idle (gpointer data)
{
  struct gowl_embed_view *view = data;

  /* Remove from the embed_views hash table. The client pointer was
     saved in the hash key — iterate to find our entry.  */
  if (embed_views != NULL)
    {
      GHashTableIter iter;
      gpointer key, value;

      g_hash_table_iter_init (&iter, embed_views);
      while (g_hash_table_iter_next (&iter, &key, &value))
        {
          if (value == view)
            {
              g_hash_table_iter_remove (&iter);
              break;
            }
        }
    }

  if (view->xwidget_managed)
    {
      /* The widget is owned by the xwidget display system — don't
         destroy it here.  Just hide it and null our reference so
         gowl_embed_view_free won't double-free.  The xwidget system
         will destroy the widget when the xwidget itself is killed.  */
      if (view->widget != NULL)
        gtk_widget_hide (view->widget);
      view->widget = NULL;
    }

  gowl_embed_view_free (view);
  return G_SOURCE_REMOVE;
}

/* Called on the dispatch thread when the wlr_surface is destroyed
   (client disconnected).  Must remove wl_listeners synchronously
   before wlroots frees the signal lists.  GTK cleanup is deferred
   to the main thread via idle callback.  */
static void
gowl_embed_view_on_surface_destroy (struct wl_listener *listener, void *data)
{
  struct gowl_embed_view *view =
    wl_container_of (listener, view, destroy);
  (void) data;

  /* Detach from the surface before wlroots frees it.  */
  wl_list_remove (&view->commit.link);
  wl_list_init (&view->commit.link);
  wl_list_remove (&view->destroy.link);
  wl_list_init (&view->destroy.link);

  /* Cancel any pending idle capture — the surface is gone and the
     view will be freed shortly.  g_source_remove is thread-safe for
     sources on the default main context.  */
  if (view->idle_id != 0)
    {
      g_source_remove (view->idle_id);
      view->idle_id = 0;
    }

  /* Mark client gone so event/draw handlers don't dereference it.  */
  view->client = NULL;

  /* Schedule GTK teardown on the main thread.  */
  g_idle_add (gowl_embed_view_destroy_idle, view);
}

static gboolean
gowl_embed_view_event (GtkWidget *widget, GdkEvent *event, gpointer data)
{
  struct gowl_embed_view *view = data;
  struct wlr_seat *seat;
  struct wlr_surface *surface;
  uint32_t time_ms;
  (void) widget;

  if (view->client == NULL)
    return FALSE;

  seat = gowl_compositor_get_wlr_seat (cmacs_gowl_compositor);
  surface = gowl_client_get_wlr_surface (view->client);
  if (seat == NULL || surface == NULL)
    return FALSE;

  time_ms = (uint32_t) (gdk_event_get_time (event) & 0xFFFFFFFF);

  switch (event->type)
    {
    case GDK_ENTER_NOTIFY:
      /* Pointer focus only — keyboard focus is given on click so that
         ESC can reliably return control to Emacs without hover
         immediately re-focusing the embedded client. */
      pthread_mutex_lock (&cmacs_gowl_mutex);
      wlr_seat_pointer_notify_enter (seat, surface,
                                     event->crossing.x, event->crossing.y);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return TRUE;

    case GDK_LEAVE_NOTIFY:
      pthread_mutex_lock (&cmacs_gowl_mutex);
      wlr_seat_pointer_notify_clear_focus (seat);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return TRUE;

    case GDK_MOTION_NOTIFY:
      pthread_mutex_lock (&cmacs_gowl_mutex);
      /* Ensure pointer focus — GDK_ENTER_NOTIFY may not have fired
         if the widget appeared under an already-stationary pointer. */
      wlr_seat_pointer_notify_enter (seat, surface,
                                     event->motion.x, event->motion.y);
      wlr_seat_pointer_notify_motion (seat, time_ms,
                                      event->motion.x, event->motion.y);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return TRUE;

    case GDK_BUTTON_PRESS:
    case GDK_BUTTON_RELEASE:
      {
        uint32_t btn;
        enum wl_pointer_button_state state;

        /* GDK button 1..5 → Linux BTN_LEFT..BTN_EXTRA */
        btn = event->button.button - 1 + 0x110; /* BTN_LEFT = 0x110 */
        state = (event->type == GDK_BUTTON_PRESS)
          ? WL_POINTER_BUTTON_STATE_PRESSED
          : WL_POINTER_BUTTON_STATE_RELEASED;

        pthread_mutex_lock (&cmacs_gowl_mutex);
        /* Ensure pointer focus — see GDK_MOTION_NOTIFY comment. */
        wlr_seat_pointer_notify_enter (seat, surface,
                                       event->button.x, event->button.y);
        wlr_seat_pointer_notify_button (seat, time_ms, btn, state);
        /* Click gives keyboard focus to the embedded client.
           Pass the actual keyboard state so the client doesn't
           get desynced after repeated focus cycles.

           Skipped while a layer surface holds the keyboard: a
           launcher covers the output, so a click landing on an
           embed underneath it is not the user asking to type
           there -- taking the keyboard would leave the launcher
           visible and deaf. */
        if (event->type == GDK_BUTTON_PRESS
            && !cmacs_gowl_layer_owns_keyboard ())
          {
            struct wlr_keyboard *kb = wlr_seat_get_keyboard (seat);
            if (kb)
              wlr_seat_keyboard_notify_enter (seat, surface,
                                              kb->keycodes,
                                              kb->num_keycodes,
                                              &kb->modifiers);
            else
              wlr_seat_keyboard_notify_enter (seat, surface,
                                              NULL, 0, NULL);
          }
        /* Flush immediately so the client sees the events without
           waiting for the dispatch thread's next 16ms cycle. */
        wl_display_flush_clients (
          gowl_compositor_get_wl_display (cmacs_gowl_compositor));
        pthread_mutex_unlock (&cmacs_gowl_mutex);
        direct_embed_kb_owner = view;
        return TRUE;
      }

    case GDK_SCROLL:
      {
        double dx = 0, dy = 0;
        if (event->scroll.direction == GDK_SCROLL_SMOOTH)
          {
            dx = event->scroll.delta_x * 15.0;
            dy = event->scroll.delta_y * 15.0;
          }
        else if (event->scroll.direction == GDK_SCROLL_UP)
          dy = -15.0;
        else if (event->scroll.direction == GDK_SCROLL_DOWN)
          dy = 15.0;
        else if (event->scroll.direction == GDK_SCROLL_LEFT)
          dx = -15.0;
        else if (event->scroll.direction == GDK_SCROLL_RIGHT)
          dx = 15.0;

        pthread_mutex_lock (&cmacs_gowl_mutex);
        /* Ensure pointer focus — see GDK_MOTION_NOTIFY comment. */
        wlr_seat_pointer_notify_enter (seat, surface,
                                       event->scroll.x, event->scroll.y);
        wlr_seat_pointer_notify_axis (seat, time_ms,
                                      WL_POINTER_AXIS_VERTICAL_SCROLL,
                                      dy,
                                      (int32_t) dy,
                                      WL_POINTER_AXIS_SOURCE_WHEEL,
                                      WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
        if (dx != 0.0)
          wlr_seat_pointer_notify_axis (seat, time_ms,
                                        WL_POINTER_AXIS_HORIZONTAL_SCROLL,
                                        dx,
                                        (int32_t) dx,
                                        WL_POINTER_AXIS_SOURCE_WHEEL,
                                        WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
        pthread_mutex_unlock (&cmacs_gowl_mutex);
        return TRUE;
      }

    case GDK_KEY_PRESS:
    case GDK_KEY_RELEASE:
      {
        /* Escape returns keyboard focus to Emacs. */
        if (event->type == GDK_KEY_PRESS
            && event->key.keyval == GDK_KEY_Escape
            && view->emacs_frame != NULL)
          {
            /* Tell the Wayland client it lost keyboard focus.
               The forwarder in xwidget.c manages the focus state —
               do NOT call gtk_widget_grab_focus here, as that
               triggers spurious frame focus-out events. */
            pthread_mutex_lock (&cmacs_gowl_mutex);
            wlr_seat_keyboard_notify_clear_focus (seat);
            wl_display_flush_clients (
              gowl_compositor_get_wl_display (cmacs_gowl_compositor));
            pthread_mutex_unlock (&cmacs_gowl_mutex);
            direct_embed_kb_owner = NULL;
            return TRUE;
          }

        /* Forward other keys to the embedded Wayland client. */
        uint32_t keycode = event->key.hardware_keycode - 8;
        enum wl_keyboard_key_state wl_state =
          (event->type == GDK_KEY_PRESS)
          ? WL_KEYBOARD_KEY_STATE_PRESSED
          : WL_KEYBOARD_KEY_STATE_RELEASED;
        pthread_mutex_lock (&cmacs_gowl_mutex);
        wlr_seat_keyboard_notify_key (seat, time_ms, keycode, wl_state);
        wl_display_flush_clients (
          gowl_compositor_get_wl_display (cmacs_gowl_compositor));
        pthread_mutex_unlock (&cmacs_gowl_mutex);
        return TRUE;
      }

    default:
      break;
    }

  return FALSE;
}

static void
gowl_embed_view_free (struct gowl_embed_view *view)
{
  if (view == NULL)
    return;

  if (view == direct_embed_kb_owner)
    direct_embed_kb_owner = NULL;

  wl_list_remove (&view->commit.link);
  wl_list_remove (&view->destroy.link);

  if (view->idle_id != 0)
    {
      g_source_remove (view->idle_id);
      view->idle_id = 0;
    }

  if (view->widget != NULL)
    {
      gtk_widget_destroy (view->widget);
      view->widget = NULL;
    }

  if (view->cr_surface != NULL)
    {
      cairo_surface_destroy (view->cr_surface);
      view->cr_surface = NULL;
    }

  g_free (view->pixel_buf);
  view->pixel_buf = NULL;

  g_free (view);
}

/* Give keyboard focus to the Wayland client embedded in XW.
   Called from the event forwarder in xwidget.c when the pointer enters
   a gowl xwidget area (focus-follows-mouse).  */
void
cmacs_gowl_xwidget_keyboard_enter (struct xwidget *xw)
{
  /* Xwidget focus-follows-mouse overrides direct-embed click-to-focus. */
  direct_embed_kb_owner = NULL;

  struct gowl_embed_view *gview = xw->gowl_view;
  if (gview == NULL)
    return;

  struct wlr_seat *seat
    = gowl_compositor_get_wlr_seat (cmacs_gowl_compositor);
  struct wlr_surface *surface
    = gowl_client_get_wlr_surface (gview->client);
  if (seat == NULL || surface == NULL)
    return;

  /* Focus-follows-mouse must not fight a launcher for the keyboard:
     the pointer crossing an xwidget while wofi is up is incidental,
     not intent.  See cmacs_gowl_layer_owns_keyboard. */
  if (cmacs_gowl_layer_owns_keyboard ())
    return;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  struct wlr_keyboard *kb = wlr_seat_get_keyboard (seat);
  if (kb)
    wlr_seat_keyboard_notify_enter (seat, surface,
                                    kb->keycodes, kb->num_keycodes,
                                    &kb->modifiers);
  else
    wlr_seat_keyboard_notify_enter (seat, surface, NULL, 0, NULL);
  wl_display_flush_clients (
    gowl_compositor_get_wl_display (cmacs_gowl_compositor));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
}

/* Clear keyboard focus from any embedded Wayland client.
   Called from the event forwarder in xwidget.c when the pointer
   leaves a gowl xwidget area or on Escape.  */
void
cmacs_gowl_xwidget_keyboard_leave (void)
{
  /* Don't clear compositor keyboard focus if a direct gowl-embed view
     owns it (click-to-focus model).  The xwidget's focus-follows-mouse
     leave should not interfere with a persistent click-based focus.  */
  if (direct_embed_kb_owner != NULL)
    return;

  struct wlr_seat *seat
    = gowl_compositor_get_wlr_seat (cmacs_gowl_compositor);
  if (seat == NULL)
    return;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  wlr_seat_keyboard_notify_clear_focus (seat);
  wl_display_flush_clients (
    gowl_compositor_get_wl_display (cmacs_gowl_compositor));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
}

/* ── Keyboard shortcut inhibition for nested mode ────────────────────
 *
 * When gowl runs nested inside another Wayland compositor (e.g. GNOME),
 * the parent compositor intercepts keyboard shortcuts (Super, Alt+Tab,
 * etc.) before they reach gowl.  We use the zwp_keyboard_shortcuts_
 * inhibit_manager_v1 protocol to tell the parent compositor to pass
 * ALL key events through to gowl's output surface.
 */

static struct zwp_keyboard_shortcuts_inhibit_manager_v1 *shortcuts_mgr = NULL;
static struct wl_seat *parent_seat = NULL;

/* One inhibitor per nested output surface.  A multi-monitor nested
   session gets one parent surface per output, and the parent only
   honours the inhibitor belonging to the surface that currently holds
   its keyboard focus — so every surface needs its own. */
#define CMACS_GOWL_MAX_INHIBITORS 16
static struct zwp_keyboard_shortcuts_inhibitor_v1
  *shortcuts_inhibitors[CMACS_GOWL_MAX_INHIBITORS];
static int n_shortcuts_inhibitors = 0;

/* The parent compositor tells us when inhibition actually takes hold
   (it only does so while our surface is focused).  These are the only
   direct evidence that Super really is ours, so log both. */
static void
shortcuts_inhibitor_handle_active (
  void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor)
{
  g_debug ("gowl: parent-compositor shortcut inhibition ACTIVE "
           "(Super and friends now reach gowl)");
}

static void
shortcuts_inhibitor_handle_inactive (
  void *data, struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor)
{
  g_debug ("gowl: parent-compositor shortcut inhibition inactive "
           "(nested surface unfocused)");
}

static const struct zwp_keyboard_shortcuts_inhibitor_v1_listener
shortcuts_inhibitor_listener = {
  shortcuts_inhibitor_handle_active,
  shortcuts_inhibitor_handle_inactive,
};

static void
registry_handle_global (void *data, struct wl_registry *registry,
                        uint32_t name, const char *interface,
                        uint32_t version)
{
  if (strcmp (interface,
             zwp_keyboard_shortcuts_inhibit_manager_v1_interface.name) == 0)
    shortcuts_mgr = wl_registry_bind (
      registry, name,
      &zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1);
  else if (strcmp (interface, "wl_seat") == 0 && parent_seat == NULL)
    parent_seat = wl_registry_bind (registry, name,
                                    &wl_seat_interface, 1);
}

static void
registry_handle_global_remove (void *data, struct wl_registry *registry,
                               uint32_t name)
{
  /* nothing */
}

static const struct wl_registry_listener registry_listener = {
  registry_handle_global,
  registry_handle_global_remove,
};

/* Request shortcut inhibition from the parent compositor.
   Must be called after gowl_compositor_start() in nested mode,
   BEFORE the dispatch thread starts (roundtrips the parent display
   which is safe since the parent compositor is a separate process).

   This is the same mechanism a VM viewer or remote-desktop client uses
   to "grab" the keyboard: while our surface has the parent's keyboard
   focus, the parent stops running its own bindings (GNOME's Super
   overview, Alt+Tab, …) and forwards the raw keys to us instead.

   Every failure path logs — a silent no-op here is indistinguishable
   from a compositor that just ignores us, and that cost us once
   already (see the multi-backend note below).

   NOT static — called from emacs.c --gowl handler and Fgowl_start. */
void
cmacs_gowl_inhibit_parent_shortcuts (GowlCompositor *comp)
{
  struct wl_display *parent_dpy = NULL;
  struct wl_registry *registry;
  GList *monitors, *l;
  int n_wl_outputs = 0;

  if (comp == NULL)
    return;

  if (n_shortcuts_inhibitors > 0)
    return;  /* already inhibited */

  /* Find the parent display via the OUTPUTS, not the compositor's
     top-level backend.  gowl builds its backend with
     wlr_backend_autocreate(), which always wraps the real backend in a
     multi-backend — so wlr_backend_is_wl() on it is ALWAYS false, even
     when nested, and testing it here silently disabled inhibition
     entirely.  gowl's own nested detection (on_new_output) checks
     wlr_output_is_wl() for exactly this reason; do the same.

     The monitor list is transfer-none: borrow it, never free it. */
  monitors = gowl_compositor_get_monitors (comp);
  for (l = monitors; l != NULL; l = l->next)
    {
      struct wlr_output *output =
        gowl_monitor_get_wlr_output (GOWL_MONITOR (l->data));

      if (output == NULL || !wlr_output_is_wl (output))
        continue;

      n_wl_outputs++;
      if (parent_dpy == NULL && output->backend != NULL
          && wlr_backend_is_wl (output->backend))
        parent_dpy = wlr_wl_backend_get_remote_display (output->backend);
    }

  if (n_wl_outputs == 0)
    {
      g_debug ("gowl: no nested Wayland outputs — running on DRM, "
               "nothing to inhibit");
      return;
    }

  if (parent_dpy == NULL)
    {
      g_warning ("gowl: nested output found but no remote display; "
                 "parent compositor keeps Super/Alt-Tab");
      return;
    }

  /* Bind the shortcut inhibitor manager and a wl_seat from
     the parent compositor via its registry. */
  registry = wl_display_get_registry (parent_dpy);
  wl_registry_add_listener (registry, &registry_listener, NULL);
  wl_display_roundtrip (parent_dpy);
  wl_registry_destroy (registry);

  if (shortcuts_mgr == NULL)
    {
      g_warning ("gowl: parent compositor does not implement "
                 "zwp_keyboard_shortcuts_inhibit_manager_v1; "
                 "its shortcuts (Super) cannot be captured");
      return;
    }
  if (parent_seat == NULL)
    {
      g_warning ("gowl: parent compositor exposes no wl_seat; "
                 "cannot request shortcut inhibition");
      return;
    }

  /* Inhibit on every nested output surface. */
  for (l = monitors; l != NULL; l = l->next)
    {
      struct wlr_output *output =
        gowl_monitor_get_wlr_output (GOWL_MONITOR (l->data));
      struct wl_surface *surface;
      struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor;

      if (output == NULL || !wlr_output_is_wl (output))
        continue;
      if (n_shortcuts_inhibitors >= CMACS_GOWL_MAX_INHIBITORS)
        break;

      /* wlr_wl_output_get_surface() asserts on non-wl outputs; the
         wlr_output_is_wl() test above is what makes this safe. */
      surface = wlr_wl_output_get_surface (output);
      if (surface == NULL)
        {
          g_warning ("gowl: nested output %s has no parent surface",
                     output->name ? output->name : "(unnamed)");
          continue;
        }

      inhibitor =
        zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts (
          shortcuts_mgr, surface, parent_seat);
      if (inhibitor == NULL)
        continue;

      zwp_keyboard_shortcuts_inhibitor_v1_add_listener (
        inhibitor, &shortcuts_inhibitor_listener, NULL);
      shortcuts_inhibitors[n_shortcuts_inhibitors++] = inhibitor;
    }

  wl_display_roundtrip (parent_dpy);

  if (n_shortcuts_inhibitors == 0)
    g_warning ("gowl: failed to inhibit parent-compositor shortcuts");
  else
    g_debug ("gowl: requested shortcut inhibition on %d nested "
             "output surface(s)", n_shortcuts_inhibitors);
}

/* ── Compositor dispatch thread ───────────────────────────────────────
 *
 * The gowl compositor and Emacs's GDK Wayland client share the same
 * process.  GDK does blocking wl_display_roundtrip_queue() calls that
 * wait for the compositor to respond — but the compositor can only
 * respond when wl_event_loop_dispatch() runs.  If both are on the same
 * thread, this is a deadlock.
 *
 * Solution: run the compositor event loop in a dedicated pthread.
 * The thread dispatches wl_event_loop with poll(), so it responds to
 * GDK's roundtrips without blocking the main thread (and vice versa).
 *
 * Thread safety: Emacs DEFUNs that access compositor state acquire
 * cmacs_gowl_mutex before reading/writing.  The dispatch thread holds
 * the mutex during wl_event_loop_dispatch() (which fires wlroots
 * callbacks that mutate compositor state).  Between dispatches the
 * mutex is released so DEFUNs can proceed without delay.
 *
 * Note: Wave 2 attempted to replace this with a GSource attached to
 * cmacs_glib_get_context(), relying on Emacs's main loop to pump
 * it.  That works once the main loop is running but fatally deadlocks
 * during pgtk_term_init → gtk_init → wl_display_roundtrip_queue,
 * which runs before the Emacs event loop is entered.  The pthread
 * is load-bearing during compositor bootstrap; see CmacsGowlLoopSource
 * in cmacs-gowl-loop.c for the (now unused) GSource implementation,
 * kept around because it may still be useful for a future hybrid
 * strategy.
 */

#include <poll.h>
#include <sys/eventfd.h>
#include <stdint.h>

static pthread_t cmacs_gowl_thread;
static volatile int cmacs_gowl_thread_running = 0;

/* eventfd used to wake the dispatch thread out of poll() on shutdown.
   Without it, a blocking poll() would never notice the running flag
   going to 0 and pthread_join() would hang. */
static int cmacs_gowl_wake_fd = -1;

/* cmacs_gowl_mutex is defined near the top of this file. */

static void *
cmacs_gowl_dispatch_thread (void *data)
{
  GowlCompositor *comp = (GowlCompositor *) data;
  struct wl_display *wl_dpy = gowl_compositor_get_wl_display (comp);
  struct wl_event_loop *loop = gowl_compositor_get_event_loop (comp);
  int fd = wl_event_loop_get_fd (loop);
  struct pollfd pfds[2];

  pfds[0].fd = fd;
  pfds[0].events = POLLIN;
  pfds[1].fd = cmacs_gowl_wake_fd;
  pfds[1].events = POLLIN;

  while (cmacs_gowl_thread_running)
    {
      /* Block indefinitely until either the wl_event_loop fd (wayland
         clients, DRM vblank, internal timers such as the bar tick) or
         the wake eventfd (shutdown signal) becomes readable.  No fixed
         timeout — polling at 60 Hz at idle was pinning the CPU and
         blocking deeper C-states on battery. */
      pfds[0].revents = 0;
      pfds[1].revents = 0;
      if (poll (pfds, 2, -1) < 0)
        {
          if (errno == EINTR)
            continue;
          break;
        }

      /* Drain the wake fd so the next poll() blocks again. */
      if (pfds[1].revents & POLLIN)
        {
          uint64_t val;
          ssize_t r = read (cmacs_gowl_wake_fd, &val, sizeof val);
          (void) r;
        }

      if (!cmacs_gowl_thread_running)
        break;

      pthread_mutex_lock (&cmacs_gowl_mutex);
      wl_display_flush_clients (wl_dpy);
      wl_event_loop_dispatch (loop, 0);
      wl_display_flush_clients (wl_dpy);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }

  return NULL;
}

/* Forward declaration for the prefix-key intercept (defined after
   the embed helpers). */
static gboolean cmacs_gowl_key_intercept (GowlCompositor *comp,
                                           guint modifiers, guint keysym,
                                           guint keycode, gboolean pressed,
                                           gpointer data);

/* Client-map callback: force-embed clients when embeds are pending.
   Runs on the dispatch thread (mutex held). */
static void
cmacs_gowl_client_map (GowlCompositor *comp, GowlClient *client,
                        gpointer data)
{
  (void) data;

  /* If this client was already caught by prefloat PID matching,
     it's already embedded — nothing to do. */
  if (gowl_client_get_embedded (client))
    return;

  /* If we're expecting an embed (flatpak, etc.), claim this client. */
  if (cmacs_embed_pending_count > 0)
    {
      cmacs_embed_pending_count--;
      gowl_client_set_embedded (client, TRUE);
      gowl_client_set_floating (client, TRUE);
      gowl_client_set_visible (client, FALSE);
      gowl_compositor_reparent_client (comp, client,
                                       GOWL_SCENE_LAYER_OVERLAY);
      gowl_compositor_arrange (comp, gowl_client_get_monitor (client));
    }
}

/* ── Custom keybind action: run Elisp from a compositor key ──────────
 *
 * A `custom' keybind carries an Elisp form as its arg.  gowl calls the
 * handler below from key dispatch, which runs on the COMPOSITOR
 * thread -- so it must not touch the Lisp VM.  It hands the form to
 * the Emacs main loop with g_idle_add, exactly as the clipboard bridge
 * does, and the idle callback evaluates it there through
 * cmacs_dispatch_eval (which carries the waiting_for_input guard and
 * the condition-case; under --gowl an error escaping into
 * signal_or_quit would abort the whole session).
 *
 * The consequence is that the eval is asynchronous: the key is
 * consumed immediately and the form runs on the next main-loop turn.
 * For a volume step or a menu that is invisible, and it is the only
 * safe option -- blocking the compositor thread on the Lisp VM would
 * stall every client's frame callbacks. */

static gboolean
cmacs_gowl_custom_action_idle (gpointer data)
{
  gchar *form = (gchar *) data;
  GError *err = NULL;
  gchar *result;

  result = cmacs_dispatch_eval (form, &err);
  if (result == NULL)
    {
      /* A broken form in a keybind should say so once, not wedge the
         session or fail silently on every press. */
      g_warning ("gowl custom keybind failed: %s (form was: %s)",
                 err != NULL ? err->message : "unknown error", form);
      g_clear_error (&err);
    }
  g_free (result);
  g_free (form);

  return G_SOURCE_REMOVE;
}

static gboolean
cmacs_gowl_custom_action (GowlCompositor *comp,
                           const gchar    *arg,
                           gpointer        data)
{
  (void) comp;
  (void) data;

  if (arg == NULL || arg[0] == '\0')
    return FALSE;

  g_idle_add (cmacs_gowl_custom_action_idle, g_strdup (arg));
  return true;
}

void
cmacs_gowl_start_thread (void)
{
  cmacs_gowl_ensure_mutex ();

  if (cmacs_gowl_thread_running || cmacs_gowl_compositor == NULL)
    return;

  /* Register callbacks before the dispatch thread starts.  The
     prefix-key intercept is always installed; whether it does
     anything is gated on the compositor's `prefix-key-policy'
     property (NULL = standalone behaviour, policy = redirect). */
  gowl_compositor_set_key_intercept (cmacs_gowl_compositor,
                                     cmacs_gowl_key_intercept,
                                     NULL);
  gowl_compositor_set_custom_action_handler (cmacs_gowl_compositor,
                                             cmacs_gowl_custom_action,
                                             NULL);
  gowl_compositor_set_client_map_callback (cmacs_gowl_compositor,
                                           cmacs_gowl_client_map,
                                           NULL);

  if (cmacs_gowl_wake_fd < 0)
    {
      cmacs_gowl_wake_fd = eventfd (0, EFD_CLOEXEC | EFD_NONBLOCK);
      if (cmacs_gowl_wake_fd < 0)
        {
          fprintf (stderr,
                   "cmacs: eventfd() failed for gowl wake-up: %s\n",
                   strerror (errno));
          return;
        }
    }

  cmacs_gowl_thread_running = 1;
  if (pthread_create (&cmacs_gowl_thread, NULL,
                      cmacs_gowl_dispatch_thread,
                      cmacs_gowl_compositor) != 0)
    {
      cmacs_gowl_thread_running = 0;
      close (cmacs_gowl_wake_fd);
      cmacs_gowl_wake_fd = -1;
      fprintf (stderr, "cmacs: failed to create gowl dispatch thread\n");
    }
}

static void
cmacs_gowl_stop_thread (void)
{
  if (!cmacs_gowl_thread_running)
    return;

  cmacs_gowl_thread_running = 0;

  /* Wake the dispatch thread out of poll() so it observes the flag. */
  if (cmacs_gowl_wake_fd >= 0)
    {
      uint64_t val = 1;
      ssize_t r = write (cmacs_gowl_wake_fd, &val, sizeof val);
      (void) r;
    }

  pthread_join (cmacs_gowl_thread, NULL);

  if (cmacs_gowl_wake_fd >= 0)
    {
      close (cmacs_gowl_wake_fd);
      cmacs_gowl_wake_fd = -1;
    }
}

/* ── Helper: get focused monitor ──────────────────────────────────── */

static GowlMonitor *
gowl_get_focused_monitor (void)
{
  GList *monitors;

  if (cmacs_gowl_compositor == NULL)
    return NULL;

  /* The focused client's monitor, or first monitor as fallback. */
  {
    GowlClient *focused;
    focused = gowl_compositor_get_focused_client (cmacs_gowl_compositor);
    if (focused != NULL)
      {
        gpointer mon = gowl_client_get_monitor (focused);
        if (mon != NULL)
          return GOWL_MONITOR (mon);
      }
  }

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors != NULL)
    return GOWL_MONITOR (monitors->data);

  return NULL;
}

/* Helper: resolve optional MONITOR arg or use focused. */
static GowlMonitor *
gowl_resolve_monitor (Lisp_Object monitor)
{
  if (!NILP (monitor))
    {
      GObject *obj = cmacs_gobject_unwrap (monitor);
      if (obj == NULL || !GOWL_IS_MONITOR (obj))
        error ("Not a GowlMonitor");
      return GOWL_MONITOR (obj);
    }
  return gowl_get_focused_monitor ();
}

/* Helper: unwrap a client arg. */
static GowlClient *
gowl_resolve_client (Lisp_Object client)
{
  GObject *obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");
  return GOWL_CLIENT (obj);
}

#define GOWL_CHECK_RUNNING()                         \
  do { if (cmacs_gowl_compositor == NULL)            \
         error ("Gowl compositor not running"); }    \
  while (0)


/* ── Compositor-level ESC escape-hatch ───��────────────────────────────
 *
 * Keyboard events for embedded clients travel through wlroots
 * on_kb_key, NOT through GDK.  The intercept callback fires in
 * the compositor dispatch thread before keys are forwarded to the
 * focused Wayland client.
 */

/* Return TRUE when keyboard focus currently sits on an embedded
   client — i.e. a press here would otherwise go to an embedded app.
   Identified by `gowl_client_get_embedded() == TRUE'. */
static gboolean
cmacs_gowl_focus_on_embed (GowlCompositor *comp)
{
  struct wlr_seat    *seat;
  struct wlr_surface *focused;
  GList              *clients, *l;

  seat = gowl_compositor_get_wlr_seat (comp);
  if (seat == NULL)
    return FALSE;
  focused = seat->keyboard_state.focused_surface;
  if (focused == NULL)
    return FALSE;

  clients = gowl_compositor_get_clients (comp);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = (GowlClient *) l->data;
      if (gowl_client_get_wlr_surface (c) == focused
          && gowl_client_get_embedded (c))
        return TRUE;
    }
  return FALSE;
}

/* Locate the first non-embedded client (the Emacs surface).  Used as
   the push target for a focus redirect. */
static GowlClient *
cmacs_gowl_find_emacs_client (GowlCompositor *comp)
{
  GList *clients, *l;

  clients = gowl_compositor_get_clients (comp);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = (GowlClient *) l->data;
      if (!gowl_client_get_embedded (c))
        return c;
    }
  return NULL;
}

/* Send wlr_seat_keyboard_notify_enter for the given GowlClient using
   the current keyboard modifier state.

   This deliberately bypasses gowl_compositor_focus_client() -- the
   whole point of the prefix-key redirect is to hand keys to Emacs
   without disturbing the compositor's own focus bookkeeping -- which
   means it also bypasses every guard that function applies.  So the
   one guard that must not be bypassed is re-checked here by hand: a
   keyboard-interactive layer surface (wofi and friends) holding an
   exclusive grab.

   Without this check the redirect races a launcher's map.  wofi maps,
   arrangelayers grants it the keyboard, and ~50 ms later
   `post-command-hook' -> `gowl-return-focus-to-embed' fires and takes
   the keyboard straight back to the embed.  wofi stays drawn, on top,
   covering the output -- and completely deaf: the user can neither
   type into it nor dismiss it, and cannot see that anything else is
   responding.  (Reported by Ben Doty, 2026-08-08.) */
static void
cmacs_gowl_wlr_focus_client (GowlCompositor *comp, GowlClient *target)
{
  struct wlr_seat     *seat;
  struct wlr_surface  *surf;
  struct wlr_keyboard *kb;

  seat = gowl_compositor_get_wlr_seat (comp);
  if (seat == NULL || target == NULL)
    return;

  if (cmacs_gowl_layer_owns_keyboard ())
    return;
  surf = gowl_client_get_wlr_surface (target);
  if (surf == NULL)
    return;

  kb = wlr_seat_get_keyboard (seat);
  if (kb != NULL)
    wlr_seat_keyboard_notify_enter (seat, surf,
                                    kb->keycodes, kb->num_keycodes,
                                    &kb->modifiers);
  else
    wlr_seat_keyboard_notify_enter (seat, surf, NULL, 0, NULL);
}

/* Key intercept: called from on_kb_key() in the compositor dispatch
   thread before unhandled keys are forwarded to the focused client.
   Returns TRUE to consume, FALSE to let the key propagate.

   Strategy: if the installed GowlPrefixKeyPolicy matches the press,
   push a focus redirect on the seat (flipping focus to the Emacs
   client) and return FALSE so the key falls through to Emacs.  The
   matching pop happens via `gowl-return-focus-to-embed' called from
   Elisp's post-command-hook after the full prefix sequence is
   handled. */
static gboolean
cmacs_gowl_key_intercept (GowlCompositor *comp,
                           guint           modifiers,
                           guint           keysym,
                           guint           keycode,
                           gboolean        pressed,
                           gpointer        data)
{
  GowlPrefixKeyPolicy *policy;
  GowlClient          *emacs_target;
  GowlSeat            *seat_obj;
  gboolean             matched_prefix;
  gboolean             matched_sticky_esc;

  (void) data;

  if (!pressed)
    return FALSE;

  /* Already redirected — let keys flow to Emacs until pop. */
  if (cmacs_gowl_active_focus_token != NULL)
    return FALSE;

  /* Only act when keyboard focus is on an embedded client; otherwise
     the press already reaches Emacs naturally. */
  if (!cmacs_gowl_focus_on_embed (comp))
    return FALSE;

  /* Hardcoded sticky escape: plain ESC (no modifiers) always
     redirects focus to Emacs.  Mirrors the pre-Wave-1b ESC
     escape-hatch, minus the 200 ms timer.  C-ESC is handled as a
     regular prefix key so Emacs can bind it to a "send literal
     ESC to the embed" command. */
  matched_sticky_esc = (modifiers == 0 && keysym == XKB_KEY_Escape);

  matched_prefix = FALSE;
  if (!matched_sticky_esc)
    {
      policy = gowl_compositor_get_prefix_key_policy (comp);
      if (policy == NULL)
        return FALSE;  /* no policy installed -> standalone */
      matched_prefix = gowl_prefix_key_policy_is_prefix (
          policy, modifiers, keysym, keycode);
      if (!matched_prefix)
        return FALSE;
    }

  emacs_target = cmacs_gowl_find_emacs_client (comp);
  if (emacs_target == NULL)
    return FALSE;

  seat_obj = gowl_compositor_get_seat (comp);
  if (seat_obj == NULL)
    return FALSE;

  cmacs_gowl_active_focus_token = gowl_seat_push_focus_redirect (
      seat_obj, emacs_target,
      matched_sticky_esc
      ? GOWL_FOCUS_REASON_EXPLICIT
      : GOWL_FOCUS_REASON_PREFIX_KEY);
  cmacs_gowl_redirect_is_sticky = matched_sticky_esc;

  cmacs_gowl_wlr_focus_client (comp, emacs_target);

  /* Sticky ESC consumes the key — the user wanted to "escape"
     out of the embed, not trigger Emacs's keyboard-quit.  Prefix
     keys pass through so Emacs runs the matching command. */
  return matched_sticky_esc;
}

/* ── Module discovery ──────────────────────────────────────────────── */

/* Search for a gowl module .so by name.  Resolution order:
     0. $CMACS_GOWL_MODULE_DIR/<name>.so  (explicit override, e.g. set
        by `just run`/`just gowl` so local testing always uses the
        freshly-built modules instead of any system-installed copy);
     1. the in-tree dev build (<exe-dir>/../deps/gowl/build/release/...);
     2. the system install dir GOWL_MODULEDIR (where gowl's own
        `make install' lands modules, e.g. /usr/lib64/gowl/modules);
     3. the installed libexec location (PATH_EXEC from epaths.h).
   Returns a newly allocated path or NULL if not found. */
static gchar *
cmacs_gowl_find_module (const gchar *name)
{
  g_autofree gchar *so_name = g_strdup_printf ("%s.so", name);
  g_autofree gchar *exe_path = NULL;
  g_autofree gchar *dev_path = NULL;
  const gchar *env_dir;

  /* 0. Explicit override: a single directory of module .so files.
     Wins over both the in-tree and installed locations so a local
     build is never shadowed by a system-installed gowl. */
  env_dir = g_getenv ("CMACS_GOWL_MODULE_DIR");
  if (env_dir != NULL && env_dir[0] != '\0')
    {
      g_autofree gchar *env_path =
        g_build_filename (env_dir, so_name, NULL);
      if (g_file_test (env_path, G_FILE_TEST_EXISTS))
        return g_steal_pointer (&env_path);
    }

  /* 1. In-tree: <exe-dir>/../deps/gowl/build/release/modules/<name>.so */
  exe_path = g_file_read_link ("/proc/self/exe", NULL);
  if (exe_path != NULL)
    {
      g_autofree gchar *bin_dir = g_path_get_dirname (exe_path);
      dev_path = g_build_filename (bin_dir, "..", "deps", "gowl",
                                   "build", "release", "modules",
                                   so_name, NULL);
      if (g_file_test (dev_path, G_FILE_TEST_EXISTS))
        return g_steal_pointer (&dev_path);
    }

  /* 2. System install dir: the compile-time GOWL_MODULEDIR, which is
     where gowl's own `make install' lands modules (MODULEDIR =
     LIBDIR/gowl/modules, e.g. /usr/lib64/gowl/modules).  This is what
     makes an installed cmacs find its modules without the env
     override -- gowl installs there, and the installed cmacs is
     compiled with this path baked in (see configure.ac, mirroring the
     podomation PODOMATION_MODULEDIR pattern). */
#ifdef GOWL_MODULEDIR
  {
    g_autofree gchar *sys_path =
      g_build_filename (GOWL_MODULEDIR, so_name, NULL);
    if (g_file_test (sys_path, G_FILE_TEST_EXISTS))
      return g_steal_pointer (&sys_path);
  }
#endif

  /* 3. Installed: PATH_EXEC/gowl-modules/<name>.so
     PATH_EXEC is archlibdir (e.g. /usr/libexec/emacs/31.0.50/x86_64-...) */
  {
    g_autofree gchar *inst_path =
      g_build_filename (PATH_EXEC, "gowl-modules", so_name, NULL);
    if (g_file_test (inst_path, G_FILE_TEST_EXISTS))
      return g_steal_pointer (&inst_path);
  }

  g_debug ("gowl: module '%s' not found", name);
  return NULL;
}

/* ══════════════════════════════════════════════════════════════════════
 * COMPOSITOR LIFECYCLE
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-start", Fgowl_start, Sgowl_start, 0, 0, 0,
       doc: /* Create and start the gowl Wayland compositor.
Returns non-nil on success.  Signals an error if already running.
If the compositor was pre-started via --gowl, this just attaches
the event loop source and returns. */)
  (void)
{
  GError *err = NULL;

  /* If already started (e.g. via --gowl early init), load modules
     (the early path creates an empty module manager), set up the
     intercept/timer, and ensure the dispatch thread is running. */
  if (cmacs_gowl_compositor != NULL)
    {
      /* Load bundled modules if the manager is still empty
         (--gowl early path doesn't load any). */
      {
        GowlModuleManager *mgr =
          gowl_compositor_get_module_manager (cmacs_gowl_compositor);
        if (mgr != NULL)
          {
            g_autofree gchar *wallpaper_so =
              cmacs_gowl_find_module ("wallpaper");
            if (wallpaper_so != NULL)
              {
                g_autoptr (GError) mod_err = NULL;
                if (!gowl_module_manager_load_module (mgr, wallpaper_so,
                                                      &mod_err))
                  g_warning ("gowl: failed to load wallpaper module: %s",
                             mod_err->message);
              }
            gowl_module_manager_activate_all (mgr);
            gowl_module_manager_dispatch_startup (mgr,
                                                  cmacs_gowl_compositor);
          }
      }

      gowl_compositor_set_key_intercept (cmacs_gowl_compositor,
                                         cmacs_gowl_key_intercept,
                                         NULL);
      cmacs_gowl_start_thread ();
      return Qt;
    }

  /* If running inside an existing Wayland session, tell wlroots to
     use the nested Wayland backend rather than trying DRM/libseat.
     Use GDK to detect this reliably — env vars like WAYLAND_DISPLAY
     may not be propagated to the process by all terminal emulators. */
  {
    gboolean nested = FALSE;
    const char *wl_display = getenv ("WAYLAND_DISPLAY");

    if (wl_display != NULL && wl_display[0] != '\0')
      nested = TRUE;

#if defined (HAVE_PGTK) && defined (GDK_WINDOWING_WAYLAND)
    if (!nested)
      {
        GdkDisplay *gdk_dpy = gdk_display_get_default ();
        if (gdk_dpy != NULL && GDK_IS_WAYLAND_DISPLAY (gdk_dpy))
          {
            nested = TRUE;
            /* wlroots needs WAYLAND_DISPLAY to connect.  GDK is
               already connected to Wayland but the env var may not
               be set (e.g. terminal didn't propagate it).  Recover
               the socket name from GDK so wlroots can find it. */
            const gchar *name = gdk_display_get_name (gdk_dpy);
            if (name != NULL)
              setenv ("WAYLAND_DISPLAY", name, 0);
          }
      }
#endif

    if (nested)
      setenv ("WLR_BACKENDS", "wayland", 0);
  }

  cmacs_gowl_compositor = gowl_compositor_new ();
  if (cmacs_gowl_compositor == NULL)
    xsignal1 (Qgowl_error,
              build_string ("Failed to create GowlCompositor"));

  /* Create a default config.  Do NOT load ~/.config/gowl/config.yaml
     or any search-path config — when embedded, the application (cmacs)
     owns all configuration via Elisp / GI.  gowl_config_new() provides
     sane defaults; adjust at runtime with (gobject-set (gowl-config-object) ...)
     or (gowl-reload-config "/path/to/config.yaml").

     Do NOT unref — the compositor stores a borrowed reference, so
     cmacs owns the lifetime.  Released in gowl-stop via g_clear_object. */
  {
    GowlConfig *config = gowl_config_new ();
    gowl_compositor_set_config (cmacs_gowl_compositor, config);
  }

  /* Load modules.  Same ownership rule as config above. */
  {
    GowlModuleManager *mgr = gowl_module_manager_new ();

    /* Load the bundled wallpaper module. */
    {
      g_autofree gchar *wallpaper_so = cmacs_gowl_find_module ("wallpaper");
      if (wallpaper_so != NULL)
        {
          g_autoptr (GError) mod_err = NULL;
          if (!gowl_module_manager_load_module (mgr, wallpaper_so, &mod_err))
            g_warning ("gowl: failed to load wallpaper module: %s",
                       mod_err->message);
        }
    }

    gowl_module_manager_activate_all (mgr);
    gowl_compositor_set_module_manager (cmacs_gowl_compositor, mgr);
  }

  if (!gowl_compositor_start (cmacs_gowl_compositor, &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      g_clear_object (&cmacs_gowl_compositor);
      xsignal1 (Qgowl_error, msg);
    }

  /* Dispatch startup hooks so modules (e.g. wallpaper) can cache the
     compositor reference.  Must happen after gowl_compositor_start(). */
  {
    GowlModuleManager *mgr =
      gowl_compositor_get_module_manager (cmacs_gowl_compositor);
    if (mgr != NULL)
      gowl_module_manager_dispatch_startup (mgr, cmacs_gowl_compositor);
  }

  /* Prefix-key interception: dispatch thread consults the compositor's
     prefix-key-policy (set from Elisp via `cmacs-gowl-focus.el') to
     decide when to redirect keyboard focus to Emacs.  Install the
     intercept unconditionally; it short-circuits when the policy is
     unset (standalone / nested). */
  gowl_compositor_set_key_intercept (cmacs_gowl_compositor,
                                     cmacs_gowl_key_intercept, NULL);

  /* If we came up nested inside another compositor, ask it to stop
     eating Super/Alt-Tab while our surface is focused.  No-op on DRM.
     Must run before the dispatch thread so the parent-display
     roundtrip stays on this thread. */
  cmacs_gowl_inhibit_parent_shortcuts (cmacs_gowl_compositor);

  cmacs_gowl_start_thread ();

  return Qt;
}

DEFUN ("gowl-stop", Fgowl_stop, Sgowl_stop, 0, 0, 0,
       doc: /* Shut down the gowl compositor. */)
  (void)
{
  if (cmacs_gowl_compositor != NULL)
    {
      cmacs_gowl_stop_thread ();
      gowl_compositor_quit (cmacs_gowl_compositor);
      g_clear_object (&cmacs_gowl_compositor);
    }
  return Qnil;
}

DEFUN ("gowl-running-p", Fgowl_running_p, Sgowl_running_p, 0, 0, 0,
       doc: /* Return non-nil if the gowl compositor is running. */)
  (void)
{
  return cmacs_gowl_compositor != NULL ? Qt : Qnil;
}

DEFUN ("gowl-grant-focus-to-emacs", Fgowl_grant_focus_to_emacs,
       Sgowl_grant_focus_to_emacs, 0, 0, 0,
       doc: /* Force keyboard focus to the Emacs client right now.
Saves the currently focused gowl client on the seat focus-redirect
stack and moves focus to the first non-embedded client.  Pair with
`gowl-return-focus-to-embed' to restore the saved focus.

This is the explicit entry point the prefix-key machinery uses under
the hood; you can also call it from Elisp directly to claim keyboard
focus unconditionally (e.g. from a minibuffer prompt in a program
that the embed has been stealing keys from).

Returns t on success, nil if gowl is not running, if a
keyboard-interactive layer surface currently holds the keyboard, or if
there is no non-embedded client to focus.  */)
  (void)
{
  GowlClient *emacs_target;
  GowlSeat   *seat_obj;

  GOWL_CHECK_RUNNING ();

  /* A launcher / on-screen keyboard holding an exclusive grab
     outranks even an explicit grant: taking the keyboard here would
     leave it visible on top of the output and deaf. */
  if (cmacs_gowl_layer_owns_keyboard ())
    return Qnil;

  if (cmacs_gowl_active_focus_token != NULL)
    /* Already redirected — keep the existing token, just idempotent. */
    return Qt;

  emacs_target = cmacs_gowl_find_emacs_client (cmacs_gowl_compositor);
  if (emacs_target == NULL)
    return Qnil;

  seat_obj = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat_obj == NULL)
    return Qnil;

  cmacs_gowl_active_focus_token = gowl_seat_push_focus_redirect (
      seat_obj, emacs_target, GOWL_FOCUS_REASON_EXPLICIT);
  /* Explicit Elisp grants are sticky: the caller wanted to stay
     in Emacs, not run one command and snap back.  Use
     `gowl-return-focus-to-embed' to undo. */
  cmacs_gowl_redirect_is_sticky = TRUE;
  cmacs_gowl_wlr_focus_client (cmacs_gowl_compositor, emacs_target);
  wl_display_flush_clients (
    gowl_compositor_get_wl_display (cmacs_gowl_compositor));

  return Qt;
}

DEFUN ("gowl-return-focus-to-embed", Fgowl_return_focus_to_embed,
       Sgowl_return_focus_to_embed, 0, 0, 0,
       doc: /* Restore the embed focus saved by `gowl-grant-focus-to-emacs'.
Pops the active #GowlFocusToken and re-sends a wlr_seat keyboard
enter for the recorded client.  No-op if no redirect is active.

Also a no-op while a keyboard-interactive layer surface (a launcher
such as wofi, an on-screen keyboard) holds the keyboard: the redirect
token is deliberately left on the stack so that this runs again from
`post-command-hook' once the launcher goes away.  Popping the token
here would hand the keyboard back to the embed and leave the launcher
visible but deaf.

Returns t if a token was popped, nil otherwise.  */)
  (void)
{
  GowlSeat   *seat_obj;
  gpointer    saved;
  GowlClient *target;

  if (cmacs_gowl_compositor == NULL
      || cmacs_gowl_active_focus_token == NULL)
    return Qnil;

  /* Keep the token: `post-command-hook' calls this after every
     command, so the pop happens on the first command after the
     launcher unmaps.  The grab is derived from live surface state,
     so it cannot wedge the redirect permanently. */
  if (cmacs_gowl_layer_owns_keyboard ())
    return Qnil;

  seat_obj = gowl_compositor_get_seat (cmacs_gowl_compositor);
  saved = gowl_focus_token_get_saved_client (
      cmacs_gowl_active_focus_token);
  target = (GowlClient *) saved;

  /* Pop first so the GowlSeat tracker is consistent even if the
     downstream wlr focus move below fails. */
  gowl_seat_pop_focus_redirect (seat_obj, cmacs_gowl_active_focus_token);
  cmacs_gowl_active_focus_token = NULL;
  cmacs_gowl_redirect_is_sticky = FALSE;

  if (target != NULL)
    cmacs_gowl_wlr_focus_client (cmacs_gowl_compositor, target);
  wl_display_flush_clients (
    gowl_compositor_get_wl_display (cmacs_gowl_compositor));

  return Qt;
}

DEFUN ("gowl-focus-redirect-active-p", Fgowl_focus_redirect_active_p,
       Sgowl_focus_redirect_active_p, 0, 0, 0,
       doc: /* Return non-nil if a prefix-key focus redirect is active.
Useful for post-command-hook gating — Elisp only has to call
`gowl-return-focus-to-embed' when this returns t.  */)
  (void)
{
  return cmacs_gowl_active_focus_token != NULL ? Qt : Qnil;
}

DEFUN ("gowl-focus-redirect-sticky-p", Fgowl_focus_redirect_sticky_p,
       Sgowl_focus_redirect_sticky_p, 0, 0, 0,
       doc: /* Return non-nil if the active focus redirect is "sticky".
Sticky redirects (plain ESC) stay put until the user explicitly
returns focus to the embed — they do NOT auto-pop after the next
command.  Regular prefix-key redirects (C-x etc) do auto-pop and
return nil here.  Returns nil when no redirect is active.  */)
  (void)
{
  return (cmacs_gowl_active_focus_token != NULL
          && cmacs_gowl_redirect_is_sticky) ? Qt : Qnil;
}

/* -----------------------------------------------------------------
 * Workspace DEFUNs.  Delegate to the compositor's installed
 * GowlWorkspaceProvider.  When no provider is installed every
 * function returns nil / 0 — standalone gowl + nested behaviour.
 * ----------------------------------------------------------------- */

static GowlWorkspaceProvider *
cmacs_gowl_provider_or_null (void)
{
  if (cmacs_gowl_compositor == NULL)
    return NULL;
  return gowl_compositor_get_workspace_provider (cmacs_gowl_compositor);
}

DEFUN ("gowl-workspace-provider-installed-p",
       Fgowl_workspace_provider_installed_p,
       Sgowl_workspace_provider_installed_p, 0, 0, 0,
       doc: /* Return non-nil if a workspace provider is attached.
cmacs `--gowl' installs a `GowlFrameWorkspaceManager' at mode
enable; standalone gowl leaves the compositor without a provider.  */)
  (void)
{
  return cmacs_gowl_provider_or_null () != NULL ? Qt : Qnil;
}

DEFUN ("gowl-install-frame-workspace-manager",
       Fgowl_install_frame_workspace_manager,
       Sgowl_install_frame_workspace_manager, 0, 0, 0,
       doc: /* Install the default GowlFrameWorkspaceManager.
A one-workspace-per-frame provider is attached to the compositor,
which takes over emitting the `workspace-*` signals.  Call once at
mode enable; subsequent calls are no-ops (the existing provider is
retained).

Returns t on success, nil if gowl is not running.  */)
  (void)
{
  GowlWorkspaceProvider *existing;
  GowlFrameWorkspaceManager *mgr;

  GOWL_CHECK_RUNNING ();
  pthread_mutex_lock (&cmacs_gowl_mutex);
  existing = gowl_compositor_get_workspace_provider (cmacs_gowl_compositor);
  if (existing != NULL)
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qt;
    }

  mgr = gowl_frame_workspace_manager_new ();
  gowl_compositor_set_workspace_provider (
      cmacs_gowl_compositor,
      GOWL_WORKSPACE_PROVIDER (mgr));
  g_object_unref (mgr);  /* compositor holds its own ref */
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-uninstall-workspace-provider",
       Fgowl_uninstall_workspace_provider,
       Sgowl_uninstall_workspace_provider, 0, 0, 0,
       doc: /* Detach any installed workspace provider.
Subsequent workspace DEFUNs will return nil.  Useful when
disabling cmacs-gowl-mode while keeping gowl running.

Returns t on success.  */)
  (void)
{
  GOWL_CHECK_RUNNING ();
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_set_workspace_provider (cmacs_gowl_compositor, NULL);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-workspace-create", Fgowl_workspace_create,
       Sgowl_workspace_create, 0, 2, 0,
       doc: /* Allocate a new workspace and return its numeric id.
Optional NAME is a display string (nil for none).  Optional TAG-MASK
is an integer tag bitmask (default 1, meaning "tag 1 visible").
Emits the compositor's `workspace-created' signal on success.

Returns the new workspace id (integer), or nil when no workspace
provider is installed.  */)
  (Lisp_Object name, Lisp_Object tag_mask)
{
  GowlWorkspaceProvider *provider;
  GowlWorkspace         *ws;
  const gchar           *name_c = NULL;
  guint32                mask   = 1;
  guint64                id_val;

  GOWL_CHECK_RUNNING ();
  provider = cmacs_gowl_provider_or_null ();
  if (provider == NULL)
    return Qnil;

  if (STRINGP (name))
    name_c = SSDATA (name);
  if (FIXNUMP (tag_mask))
    mask = (guint32) XFIXNUM (tag_mask);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ws = gowl_workspace_provider_create (provider, name_c, mask);
  if (ws == NULL)
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qnil;
    }
  gowl_compositor_emit_workspace_created (cmacs_gowl_compositor, ws);
  id_val = gowl_workspace_get_id (ws);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return make_uint (id_val);
}

DEFUN ("gowl-workspace-switch", Fgowl_workspace_switch,
       Sgowl_workspace_switch, 1, 1, 0,
       doc: /* Make workspace ID the active workspace.
Emits `workspace-switched' with the previous and new workspace.
Returns t on success, nil if no provider is installed, the id is
unknown, or the workspace was already active.  */)
  (Lisp_Object id)
{
  GowlWorkspaceProvider *provider;
  GowlWorkspace         *from;
  GowlWorkspace         *to;

  CHECK_FIXNUM (id);
  GOWL_CHECK_RUNNING ();
  provider = cmacs_gowl_provider_or_null ();
  if (provider == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  to = gowl_workspace_provider_lookup (provider, XFIXNUM (id));
  if (to == NULL)
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qnil;
    }

  from = gowl_workspace_provider_get_current (provider);
  if (!gowl_workspace_provider_switch_to (provider, to))
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qnil;
    }

  gowl_compositor_emit_workspace_switched (cmacs_gowl_compositor,
                                            from, to);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-workspace-destroy", Fgowl_workspace_destroy,
       Sgowl_workspace_destroy, 1, 1, 0,
       doc: /* Remove workspace ID.
Emits `workspace-destroyed'.  Returns t on success, nil on
unknown id or when no provider is installed.  */)
  (Lisp_Object id)
{
  GowlWorkspaceProvider *provider;
  GowlWorkspace         *ws;

  CHECK_FIXNUM (id);
  GOWL_CHECK_RUNNING ();
  provider = cmacs_gowl_provider_or_null ();
  if (provider == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ws = gowl_workspace_provider_lookup (provider, XFIXNUM (id));
  if (ws == NULL)
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qnil;
    }

  /* Hold a reference across the emit — the provider is about to
     drop its last ref when destroy() returns, and we want
     listeners to see a valid GObject during dispatch. */
  g_object_ref (ws);
  gowl_compositor_emit_workspace_destroyed (cmacs_gowl_compositor, ws);
  gowl_workspace_provider_destroy (provider, ws);
  g_object_unref (ws);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-workspace-current", Fgowl_workspace_current,
       Sgowl_workspace_current, 0, 0, 0,
       doc: /* Return the active workspace id, or nil if none.  */)
  (void)
{
  GowlWorkspaceProvider *provider;
  GowlWorkspace         *ws;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  provider = cmacs_gowl_provider_or_null ();
  if (provider == NULL)
    return Qnil;

  ws = gowl_workspace_provider_get_current (provider);
  if (ws == NULL)
    return Qnil;

  return make_uint (gowl_workspace_get_id (ws));
}

DEFUN ("gowl-workspace-list", Fgowl_workspace_list,
       Sgowl_workspace_list, 0, 0, 0,
       doc: /* Return a list of workspace plists.
Each entry is (:id ID :name NAME :tag-mask MASK).  Empty when no
provider is installed.  */)
  (void)
{
  GowlWorkspaceProvider *provider;
  GList                 *all, *it;
  Lisp_Object            result = Qnil;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  provider = cmacs_gowl_provider_or_null ();
  if (provider == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  all = gowl_workspace_provider_list (provider);
  for (it = all; it != NULL; it = it->next)
    {
      GowlWorkspace *ws   = (GowlWorkspace *) it->data;
      const gchar   *name = gowl_workspace_get_name (ws);

      /* Build (:id ID :name NAME :tag-mask MASK) as a plist.
         Plain string keys so we don't depend on any specific
         QC-symbol already existing in this translation unit. */
      Lisp_Object plist = Qnil;
      plist = Fcons (make_uint (gowl_workspace_get_tag_mask (ws)), plist);
      plist = Fcons (intern_c_string (":tag-mask"), plist);
      plist = Fcons (name != NULL ? build_string (name) : Qnil, plist);
      plist = Fcons (intern_c_string (":name"), plist);
      plist = Fcons (make_uint (gowl_workspace_get_id (ws)), plist);
      plist = Fcons (intern_c_string (":id"), plist);

      result = Fcons (plist, result);
    }
  g_list_free (all);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Fnreverse (result);
}

/* Singleton default session provider, lazily created on first use. */
static GowlSessionProvider *cmacs_gowl_session_provider = NULL;

static GowlSessionProvider *
cmacs_gowl_get_session_provider (void)
{
  if (cmacs_gowl_session_provider == NULL)
    cmacs_gowl_session_provider =
      GOWL_SESSION_PROVIDER (gowl_session_default_new ());
  return cmacs_gowl_session_provider;
}

DEFUN ("gowl-session-save", Fgowl_session_save, Sgowl_session_save,
       1, 1, 0,
       doc: /* Write the compositor session state to PATH as YAML.
PATH is a filesystem path; it is overwritten if it exists.  The
snapshot includes per-monitor mfact/nmaster and a per-client
summary (app-id, title, tags, floating, geometry).  Signals nil on
error (with message) or the path on success.  */)
  (Lisp_Object path)
{
  g_autoptr (GFile) file = NULL;
  g_autoptr (GError) err = NULL;

  CHECK_STRING (path);
  GOWL_CHECK_RUNNING ();

  file = g_file_new_for_path (SSDATA (path));
  pthread_mutex_lock (&cmacs_gowl_mutex);
  if (!gowl_session_provider_save (cmacs_gowl_get_session_provider (),
                                   cmacs_gowl_compositor, file, &err))
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      message ("gowl-session-save failed: %s",
               err != NULL ? err->message : "(unknown)");
      return Qnil;
    }
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return path;
}

DEFUN ("gowl-session-restore", Fgowl_session_restore, Sgowl_session_restore,
       1, 1, 0,
       doc: /* Load session state from PATH and apply it.
Per-monitor layout parameters are applied immediately; per-client
entries are queued as rules against the running GowlConfig so that
subsequently-mapped clients matching by app-id inherit the saved
tags/floating/geometry.

Returns t on success, nil on error.  */)
  (Lisp_Object path)
{
  g_autoptr (GFile) file = NULL;
  g_autoptr (GError) err = NULL;

  CHECK_STRING (path);
  GOWL_CHECK_RUNNING ();

  file = g_file_new_for_path (SSDATA (path));
  pthread_mutex_lock (&cmacs_gowl_mutex);
  if (!gowl_session_provider_load (cmacs_gowl_get_session_provider (),
                                   cmacs_gowl_compositor, file, &err))
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      message ("gowl-session-restore failed: %s",
               err != NULL ? err->message : "(unknown)");
      return Qnil;
    }
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-set-prefix-key-policy",
       Fgowl_set_prefix_key_policy, Sgowl_set_prefix_key_policy,
       1, 1, 0,
       doc: /* Install a list of keybind STRINGS as the prefix-key policy.
Each element is a keybind string parseable by `gowl-keybind-parse'
(e.g. "Control+x", "Control+c", "Meta+x", "Control+g").  When a
press matches one of these WHILE an embedded client has keyboard
focus, the compositor redirects focus to Emacs so the key chain
reaches the minibuffer/keymap as expected.

Passing nil clears any installed policy and restores standalone
compositor behaviour (embeds own keyboard focus uninterrupted).

Returns t on success.  */)
  (Lisp_Object keys)
{
  GowlStaticPrefixKeyPolicy *policy;

  GOWL_CHECK_RUNNING ();

  if (NILP (keys))
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      gowl_compositor_set_prefix_key_policy (cmacs_gowl_compositor, NULL);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qt;
    }

  CHECK_LIST (keys);

  policy = gowl_static_prefix_key_policy_new ();
  {
    Lisp_Object tail = keys;
    while (CONSP (tail))
      {
        Lisp_Object entry = XCAR (tail);
        if (STRINGP (entry))
          gowl_static_prefix_key_policy_add_from_string (
              policy, SSDATA (entry));
        tail = XCDR (tail);
      }
  }

  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_set_prefix_key_policy (
      cmacs_gowl_compositor,
      GOWL_PREFIX_KEY_POLICY (policy));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  /* set_prefix_key_policy takes its own ref; drop ours. */
  g_object_unref (policy);

  return Qt;
}

DEFUN ("gowl-socket-name", Fgowl_socket_name, Sgowl_socket_name, 0, 0, 0,
       doc: /* Return the Wayland socket name of the gowl compositor.
This is the value of WAYLAND_DISPLAY that clients should use to
connect (e.g. "wayland-1").  Returns nil if the compositor is not
running or the socket name is unavailable. */)
  (void)
{
  const gchar *name;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  name = gowl_compositor_get_socket_name (cmacs_gowl_compositor);
  if (name == NULL)
    return Qnil;

  return build_string (name);
}


/* ══════════════════════════════════════════════════════════════════════
 * GOBJECT ACCESSORS — full runtime GI control
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-compositor", Fgowl_compositor, Sgowl_compositor, 0, 0, 0,
       doc: /* Return the GowlCompositor GObject.
This allows full GI control: gobject-get, gobject-set, gobject-connect,
gobject-list-properties, gobject-list-signals all work on this object.
From bacon: cmacsgi gi-method compositor "get_clients" */)
  (void)
{
  GOWL_CHECK_RUNNING ();
  return cmacs_gobject_wrap (G_OBJECT (cmacs_gowl_compositor));
}

DEFUN ("gowl-config-object", Fgowl_config_object, Sgowl_config_object,
       0, 0, 0,
       doc: /* Return the GowlConfig GObject for runtime config changes.
Use gobject-set to modify properties at runtime:
  (gobject-set (gowl-config-object) "border-width" 3) */)
  (void)
{
  GowlConfig *config;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (config));
}

DEFUN ("gowl-module-manager", Fgowl_module_manager, Sgowl_module_manager,
       0, 0, 0,
       doc: /* Return the GowlModuleManager GObject. */)
  (void)
{
  GowlModuleManager *mgr;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (mgr));
}


/* ══════════════════════════════════════════════════════════════════════
 * CLIENT MANAGEMENT
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-list-clients", Fgowl_list_clients, Sgowl_list_clients,
       0, 0, 0,
       doc: /* Return a list of managed window client objects. */)
  (void)
{
  GList *clients, *l;
  Lisp_Object result = Qnil;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
  for (l = clients; l != NULL; l = l->next)
    result = Fcons (cmacs_gobject_wrap (G_OBJECT (l->data)), result);

  return Fnreverse (result);
}

DEFUN ("gowl-client-count", Fgowl_client_count, Sgowl_client_count,
       0, 0, 0,
       doc: /* Return the number of managed clients. */)
  (void)
{
  if (cmacs_gowl_compositor == NULL)
    return make_fixnum (0);
  return make_fixnum (
    (EMACS_INT)gowl_compositor_get_client_count (cmacs_gowl_compositor));
}

DEFUN ("gowl-focused-client", Fgowl_focused_client, Sgowl_focused_client,
       0, 0, 0,
       doc: /* Return the currently focused client, or nil. */)
  (void)
{
  GowlClient *c;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  c = gowl_compositor_get_focused_client (cmacs_gowl_compositor);
  if (c == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (c));
}

DEFUN ("gowl-focus-client", Fgowl_focus_client, Sgowl_focus_client,
       1, 1, 0,
       doc: /* Focus CLIENT, revealing its tag (workspace) on its monitor.
Switches CLIENT's monitor to show CLIENT's tags, gives it keyboard
focus, and re-tiles — so this works even when CLIENT lives on a tag
or monitor that is not currently viewed.  Embedded clients (which
live inside Emacs windows) only have their tag revealed; keyboard
focus stays with Emacs. */)
  (Lisp_Object client)
{
  GowlClient *c;

  GOWL_CHECK_RUNNING ();
  c = gowl_resolve_client (client);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_show_client (cmacs_gowl_compositor, c);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-close-client", Fgowl_close_client, Sgowl_close_client,
       1, 1, 0,
       doc: /* Close CLIENT window. */)
  (Lisp_Object client)
{
  gowl_client_close (gowl_resolve_client (client));
  return Qnil;
}

DEFUN ("gowl-client-info", Fgowl_client_info, Sgowl_client_info,
       1, 1, 0,
       doc: /* Return an alist of info about CLIENT.
Keys: title, app-id, tags, floating, embedded, geometry. */)
  (Lisp_Object client)
{
  GowlClient *c;
  gint x, y, w, h;

  c = gowl_resolve_client (client);
  gowl_client_get_geometry (c, &x, &y, &w, &h);

  return CALLN (Flist,
    Fcons (intern_c_string ("title"),
           build_string (gowl_client_get_title (c) ? : "")),
    Fcons (intern_c_string ("app-id"),
           build_string (gowl_client_get_app_id (c) ? : "")),
    Fcons (intern_c_string ("tags"),
           make_fixnum ((EMACS_INT)gowl_client_get_tags (c))),
    Fcons (intern_c_string ("floating"),
           gowl_client_get_floating (c) ? Qt : Qnil),
    Fcons (intern_c_string ("embedded"),
           gowl_client_get_embedded (c) ? Qt : Qnil),
    Fcons (intern_c_string ("geometry"),
           list4 (make_fixnum (x), make_fixnum (y),
                  make_fixnum (w), make_fixnum (h))));
}

DEFUN ("gowl-move-client", Fgowl_move_client, Sgowl_move_client,
       3, 3, 0,
       doc: /* Move CLIENT to position X, Y in compositor coordinates.
Updates the scene graph and sends a configure to the client. */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y)
{
  GowlClient *c;
  gint cx, cy, cw, ch;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);

  c = gowl_resolve_client (client);
  gowl_client_get_geometry (c, &cx, &cy, &cw, &ch);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_resize_client (cmacs_gowl_compositor, c,
                                 (gint) XFIXNUM (x), (gint) XFIXNUM (y),
                                 cw, ch);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qnil;
}

DEFUN ("gowl-resize-client", Fgowl_resize_client, Sgowl_resize_client,
       3, 3, 0,
       doc: /* Resize CLIENT to W x H pixels.
Updates the scene graph and sends a configure to the client. */)
  (Lisp_Object client, Lisp_Object w, Lisp_Object h)
{
  GowlClient *c;
  gint cx, cy, cw, ch;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = gowl_resolve_client (client);
  gowl_client_get_geometry (c, &cx, &cy, &cw, &ch);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_resize_client (cmacs_gowl_compositor, c,
                                 cx, cy,
                                 (gint) XFIXNUM (w), (gint) XFIXNUM (h));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qnil;
}

DEFUN ("gowl-client-set-geometry", Fgowl_client_set_geometry,
       Sgowl_client_set_geometry, 5, 5, 0,
       doc: /* Set CLIENT's geometry to X Y W H in one call.
Wraps `gowl-move-client' + `gowl-resize-client' into a single
compositor `resize-client' call so the scene graph and the client's
xdg-configure see a consistent rectangle on the same tick.  Used
by the buffer-mode reconciler to push `window-body-pixel-edges'
to the compositor on every Emacs window change.  */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
  GowlClient *c;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_resize_client (cmacs_gowl_compositor, c,
                                 (gint) XFIXNUM (x), (gint) XFIXNUM (y),
                                 (gint) XFIXNUM (w), (gint) XFIXNUM (h));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-client-add-mirror", Fgowl_client_add_mirror,
       Sgowl_client_add_mirror, 5, 5, 0,
       doc: /* Add a mirror scene node duplicating CLIENT at X Y W H.
The mirror displays CLIENT's root surface buffer at the given
compositor coordinates and updates on every client commit.
Returns the new mirror's view id (integer), which the caller uses
for subsequent update/remove calls.

Used under cmacs `--gowl` to render the same embedded client in
multiple Emacs windows (e.g. after C-x 3 over a gowl app buffer).
Returns nil on failure.  */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
  GowlClient *c;
  GowlMirror *m;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  m = gowl_client_add_mirror (c,
                               (gint) XFIXNUM (x), (gint) XFIXNUM (y),
                               (gint) XFIXNUM (w), (gint) XFIXNUM (h));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  if (m == NULL)
    return Qnil;

  return make_uint (gowl_mirror_get_view_id (m));
}

DEFUN ("gowl-client-update-mirror", Fgowl_client_update_mirror,
       Sgowl_client_update_mirror, 6, 6, 0,
       doc: /* Reposition mirror VIEW-ID belonging to CLIENT.
Moves and resizes the mirror's scene node in one call.  Returns
t on success, nil if VIEW-ID does not match any mirror of CLIENT.  */)
  (Lisp_Object client, Lisp_Object view_id,
   Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
  GowlClient *c;
  GowlMirror *match;
  GList      *all, *it;
  guint64     target;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (view_id);
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = gowl_resolve_client (client);
  target = (guint64) XFIXNUM (view_id);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  match = NULL;
  all = gowl_client_list_mirrors (c);
  for (it = all; it != NULL; it = it->next)
    {
      GowlMirror *m = GOWL_MIRROR (it->data);
      if (gowl_mirror_get_view_id (m) == target)
        {
          match = m;
          break;
        }
    }
  g_list_free (all);

  if (match == NULL)
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qnil;
    }

  gowl_client_update_mirror (c, match,
                              (gint) XFIXNUM (x), (gint) XFIXNUM (y),
                              (gint) XFIXNUM (w), (gint) XFIXNUM (h));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-client-remove-mirror", Fgowl_client_remove_mirror,
       Sgowl_client_remove_mirror, 2, 2, 0,
       doc: /* Remove mirror VIEW-ID from CLIENT.
Destroys the mirror's scene node and drops the commit listener.
Returns t on success, nil if VIEW-ID does not match.  */)
  (Lisp_Object client, Lisp_Object view_id)
{
  GowlClient *c;
  GowlMirror *match;
  GList      *all, *it;
  guint64     target;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (view_id);

  c = gowl_resolve_client (client);
  target = (guint64) XFIXNUM (view_id);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  match = NULL;
  all = gowl_client_list_mirrors (c);
  for (it = all; it != NULL; it = it->next)
    {
      GowlMirror *m = GOWL_MIRROR (it->data);
      if (gowl_mirror_get_view_id (m) == target)
        {
          match = m;
          break;
        }
    }
  g_list_free (all);

  if (match == NULL)
    {
      pthread_mutex_unlock (&cmacs_gowl_mutex);
      return Qnil;
    }

  gowl_client_remove_mirror (c, match);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-client-list-mirrors", Fgowl_client_list_mirrors,
       Sgowl_client_list_mirrors, 1, 1, 0,
       doc: /* Return a list of mirror plists for CLIENT.
Each entry is (:view-id ID :x X :y Y :w W :h H).  Empty list if
CLIENT has no mirrors.  */)
  (Lisp_Object client)
{
  GowlClient  *c;
  GList       *all, *it;
  Lisp_Object  result = Qnil;

  GOWL_CHECK_RUNNING ();
  c = gowl_resolve_client (client);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  all = gowl_client_list_mirrors (c);
  for (it = all; it != NULL; it = it->next)
    {
      GowlMirror *m = GOWL_MIRROR (it->data);
      gint        mx, my, mw, mh;
      Lisp_Object plist = Qnil;

      gowl_mirror_get_geometry (m, &mx, &my, &mw, &mh);
      plist = Fcons (make_fixnum (mh), plist);
      plist = Fcons (intern_c_string (":h"), plist);
      plist = Fcons (make_fixnum (mw), plist);
      plist = Fcons (intern_c_string (":w"), plist);
      plist = Fcons (make_fixnum (my), plist);
      plist = Fcons (intern_c_string (":y"), plist);
      plist = Fcons (make_fixnum (mx), plist);
      plist = Fcons (intern_c_string (":x"), plist);
      plist = Fcons (make_uint (gowl_mirror_get_view_id (m)), plist);
      plist = Fcons (intern_c_string (":view-id"), plist);

      result = Fcons (plist, result);
    }
  g_list_free (all);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Fnreverse (result);
}

DEFUN ("gowl-set-tags", Fgowl_set_tags, Sgowl_set_tags, 2, 2, 0,
       doc: /* Set TAGS bitmask on CLIENT. */)
  (Lisp_Object client, Lisp_Object tags)
{
  CHECK_FIXNAT (tags);
  gowl_client_set_tags (gowl_resolve_client (client),
                        (guint32)XFIXNAT (tags));
  return Qnil;
}

DEFUN ("gowl-toggle-client-floating", Fgowl_toggle_client_floating,
       Sgowl_toggle_client_floating, 1, 1, 0,
       doc: /* Toggle floating state of CLIENT.
Reparents CLIENT's scene node to the FLOAT or TILE layer and
re-arranges the layout so neighbouring tiled clients reclaim
or yield space.  Signals an error if CLIENT is embedded — use
`cmacs-gowl-embed-release' to free an embedded client first. */)
  (Lisp_Object client)
{
  GowlClient *c = gowl_resolve_client (client);
  if (gowl_client_get_embedded (c))
    error ("gowl: client is embedded; release it first");
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_set_floating (cmacs_gowl_compositor, c,
                                 !gowl_client_get_floating (c));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return gowl_client_get_floating (c) ? Qt : Qnil;
}

DEFUN ("gowl-set-client-floating", Fgowl_set_client_floating,
       Sgowl_set_client_floating, 2, 2, 0,
       doc: /* Set floating state of CLIENT to FLOATING.
Reparents the scene node to the FLOAT or TILE layer and
re-arranges the layout.  Unlike `gowl-toggle-client-floating'
this accepts embedded clients — callers releasing a previously
embedded client should clear `gowl-set-client-embedded' first
and then use this to move the client into the float layer. */)
  (Lisp_Object client, Lisp_Object floating)
{
  GowlClient *c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_set_floating (cmacs_gowl_compositor, c, !NILP (floating));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return NILP (floating) ? Qnil : Qt;
}

DEFUN ("gowl-toggle-client-fullscreen", Fgowl_toggle_client_fullscreen,
       Sgowl_toggle_client_fullscreen, 1, 1, 0,
       doc: /* Toggle fullscreen state of CLIENT. */)
  (Lisp_Object client)
{
  GowlClient *c = gowl_resolve_client (client);
  gowl_client_set_fullscreen (c, !gowl_client_get_fullscreen (c));
  return gowl_client_get_fullscreen (c) ? Qt : Qnil;
}

DEFUN ("gowl-set-client-urgent", Fgowl_set_client_urgent,
       Sgowl_set_client_urgent, 2, 2, 0,
       doc: /* Set URGENT flag on CLIENT. */)
  (Lisp_Object client, Lisp_Object urgent)
{
  gowl_client_set_urgent (gowl_resolve_client (client), !NILP (urgent));
  return Qnil;
}

DEFUN ("gowl-move-client-to-monitor", Fgowl_move_client_to_monitor,
       Sgowl_move_client_to_monitor, 2, 2, 0,
       doc: /* Move CLIENT to MONITOR. */)
  (Lisp_Object client, Lisp_Object monitor)
{
  GowlClient *c = gowl_resolve_client (client);
  GowlMonitor *mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    gowl_client_set_monitor (c, mon);
  return Qnil;
}

DEFUN ("gowl-client-pid", Fgowl_client_pid, Sgowl_client_pid, 1, 1, 0,
       doc: /* Return the PID of CLIENT's process. */)
  (Lisp_Object client)
{
  return make_fixnum ((EMACS_INT)gowl_client_get_pid (
    gowl_resolve_client (client)));
}

DEFUN ("gowl-find-client", Fgowl_find_client, Sgowl_find_client,
       1, 2, 0,
       doc: /* Find a client matching PATTERN.
Optional second arg BY is a symbol: `app-id' (default), `title',
or `pid' (PATTERN is a PID integer). */)
  (Lisp_Object pattern, Lisp_Object by)
{
  GowlClient *c = NULL;

  GOWL_CHECK_RUNNING ();

  if (!NILP (by) && EQ (by, intern_c_string ("pid")))
    {
      /* Search by PID: iterate all clients. */
      pid_t target;
      GList *clients, *l;

      CHECK_FIXNUM (pattern);
      target = (pid_t) XFIXNUM (pattern);
      clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
      for (l = clients; l != NULL; l = l->next)
        {
          GowlClient *candidate = GOWL_CLIENT (l->data);
          if (gowl_client_get_pid (candidate) == target)
            {
              c = candidate;
              break;
            }
        }
    }
  else
    {
      CHECK_STRING (pattern);
      if (!NILP (by) && EQ (by, intern_c_string ("title")))
        c = gowl_compositor_find_client_by_title (cmacs_gowl_compositor,
                                                   SSDATA (pattern));
      else
        c = gowl_compositor_find_client_by_app_id (cmacs_gowl_compositor,
                                                    SSDATA (pattern));
    }

  if (c == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (c));
}


/* ══════════════════════════════════════════════════════════════════════
 * PROCESS CONTROL
 * ══════════════════════════════════════════════════════════════════════ */

gboolean
cmacs_gowl_spawn_command (const gchar *command, GPid *pid, GError **error)
{
  const gchar *socket;
  gchar **argv;
  gchar **envp;
  GPid child_pid = 0;
  gboolean ok;

  if (cmacs_gowl_compositor == NULL)
    {
      g_set_error_literal (error, G_SPAWN_ERROR, G_SPAWN_ERROR_FAILED,
                           "gowl compositor not running");
      return FALSE;
    }

  if (!g_shell_parse_argv (command, NULL, &argv, error))
    return FALSE;

  /* Build environment: inherit current env, set Wayland hints. */
  socket = gowl_compositor_get_socket_name (cmacs_gowl_compositor);
  {
    gchar **parent_env = g_get_environ ();
    envp = g_environ_setenv (parent_env, "WAYLAND_DISPLAY",
                             socket ? socket : "", TRUE);
    /* Toolkit-specific Wayland hints — ensures Electron, GTK, Qt,
       and SDL apps connect to this compositor's Wayland socket. */
    envp = g_environ_setenv (envp, "ELECTRON_OZONE_PLATFORM_HINT",
                             "wayland", TRUE);
    envp = g_environ_setenv (envp, "MOZ_ENABLE_WAYLAND", "1", TRUE);
    envp = g_environ_setenv (envp, "QT_QPA_PLATFORM", "wayland", TRUE);
    envp = g_environ_setenv (envp, "SDL_VIDEODRIVER", "wayland", TRUE);
    envp = g_environ_setenv (envp, "GDK_BACKEND", "wayland", TRUE);
    /* Point X11 clients at gowl's own XWayland so they get a usable
       DISPLAY inside the session (e.g. raylib/GLFW apps).  Falls back to
       unsetting DISPLAY when gowl has no XWayland, so toolkits prefer
       Wayland and never connect to an inherited parent X server. */
    {
      const gchar *xdisplay =
        gowl_compositor_get_xwayland_display (cmacs_gowl_compositor);
      if (xdisplay != NULL && xdisplay[0] != '\0')
        envp = g_environ_setenv (envp, "DISPLAY", xdisplay, TRUE);
      else
        envp = g_environ_unsetenv (envp, "DISPLAY");
    }
  }

  ok = g_spawn_async (NULL, argv, envp, G_SPAWN_SEARCH_PATH,
                      NULL, NULL, &child_pid, error);
  g_strfreev (argv);
  g_strfreev (envp);

  if (ok && pid != NULL)
    *pid = child_pid;
  return ok;
}

DEFUN ("gowl-spawn", Fgowl_spawn, Sgowl_spawn, 1, 1, 0,
       doc: /* Launch COMMAND as a Wayland client.
Returns the child process PID as an integer. */)
  (Lisp_Object command)
{
  GError *err = NULL;
  GPid child_pid = 0;

  CHECK_STRING (command);
  GOWL_CHECK_RUNNING ();

  if (!cmacs_gowl_spawn_command (SSDATA (command), &child_pid, &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgowl_error, msg);
    }

  return make_fixnum ((EMACS_INT) child_pid);
}

DEFUN ("gowl-client-border-width",
       Fgowl_client_border_width, Sgowl_client_border_width,
       1, 1, 0,
       doc: /* Return CLIENT border width in pixels. */)
  (Lisp_Object client)
{
  return make_fixnum (
    (EMACS_INT) gowl_client_get_border_width (gowl_resolve_client (client)));
}

DEFUN ("gowl-set-client-border-width",
       Fgowl_set_client_border_width, Sgowl_set_client_border_width,
       2, 2, 0,
       doc: /* Set CLIENT border width to WIDTH pixels. */)
  (Lisp_Object client, Lisp_Object width)
{
  GowlClient *c;

  CHECK_FIXNAT (width);
  c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_client_set_border_width (c, (guint) XFIXNAT (width));
  /* Keep the active decorator (e.g. roundcorners) in sync with the
     new border width -- gowl_client_set_border_width only touches
     the legacy wlr_scene_rect borders. */
  gowl_compositor_refresh_client_decoration (cmacs_gowl_compositor, c);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qnil;
}

DEFUN ("gowl-set-client-visible",
       Fgowl_set_client_visible, Sgowl_set_client_visible,
       2, 2, 0,
       doc: /* Set CLIENT visibility.
Non-nil VISIBLE shows the client, nil hides it. */)
  (Lisp_Object client, Lisp_Object visible)
{
  GowlClient *c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_client_set_visible (c, !NILP (visible));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qnil;
}

DEFUN ("gowl-arrange", Fgowl_arrange, Sgowl_arrange, 0, 0, 0,
       doc: /* Recalculate the tiling layout on the selected monitor.
Reparents floating clients to the float layer and retiles
non-floating clients.  Call this after programmatically changing
a client's floating state. */)
  (void)
{
  GowlMonitor *mon;

  GOWL_CHECK_RUNNING ();
  mon = gowl_get_focused_monitor ();
  if (mon != NULL)
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      gowl_compositor_arrange (cmacs_gowl_compositor, mon);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }
  return Qnil;
}

DEFUN ("gowl-prefloat-pid", Fgowl_prefloat_pid, Sgowl_prefloat_pid,
       1, 1, 0,
       doc: /* Register PID so its client is floated and hidden on map.
The compositor will make the client floating and invisible when it
first appears, instead of tiling it.  The registration is consumed
on first match.  Used by `gowl-embed' to prevent a visual flash. */)
  (Lisp_Object pid)
{
  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (pid);
  gowl_compositor_prefloat_pid (cmacs_gowl_compositor,
                                (pid_t) XFIXNUM (pid));
  return Qnil;
}

DEFUN ("gowl-pretag-pid", Fgowl_pretag_pid, Sgowl_pretag_pid,
       2, 3, 0,
       doc: /* Register PID so its client maps onto TAGMASK.
When the next client owned by PID first appears, the compositor
places it on the TAGMASK tag set instead of the currently-viewed
tags — so the client never flashes on the active tag.  TAGMASK is an
integer bitmask (bit 0 = tag 1).  Optional MONITOR is a 0-based
monitor index to place the client on (so a tag lands on the monitor
showing it); nil or negative leaves it on the focused monitor.  The
registration is consumed on first match.  Used by
`cmacs-gowl-spawn-in-tag' to launch an application directly into a
tag (workspace) on its monitor. */)
  (Lisp_Object pid, Lisp_Object tagmask, Lisp_Object monitor)
{
  gint mon_idx = -1;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (pid);
  CHECK_FIXNAT (tagmask);
  if (!NILP (monitor))
    {
      CHECK_FIXNUM (monitor);
      mon_idx = (gint) XFIXNUM (monitor);
    }
  gowl_compositor_pretag_pid (cmacs_gowl_compositor,
                              (pid_t) XFIXNUM (pid),
                              (guint32) XFIXNAT (tagmask),
                              mon_idx);
  return Qnil;
}

DEFUN ("gowl-reparent-client", Fgowl_reparent_client, Sgowl_reparent_client,
       2, 2, 0,
       doc: /* Move CLIENT scene node to LAYER.
LAYER is an integer index: 0=bg, 1=bottom, 2=tile, 3=float,
4=top, 5=fs, 6=overlay, 7=block. */)
  (Lisp_Object client, Lisp_Object layer)
{
  GowlClient *c;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (layer);
  c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_reparent_client (cmacs_gowl_compositor, c,
                                   (gint) XFIXNAT (layer));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qnil;
}

DEFUN ("gowl-set-client-embedded", Fgowl_set_client_embedded,
       Sgowl_set_client_embedded, 2, 2, 0,
       doc: /* Mark CLIENT as embedded (non-nil) or unembedded (nil).
Embedded clients are excluded from the tiling arrange pass.
The embedder controls their position, visibility, and scene layer. */)
  (Lisp_Object client, Lisp_Object embedded)
{
  gowl_client_set_embedded (gowl_resolve_client (client),
                            !NILP (embedded));
  return Qnil;
}

DEFUN ("gowl-emacs-client", Fgowl_emacs_client, Sgowl_emacs_client,
       0, 0, 0,
       doc: /* Return the GowlClient for Emacs's own frame.
Matches by PID against the compositor's client list.
Skips embedded clients to avoid returning a hijacked surface. */)
  (void)
{
  GList *clients;
  GList *l;
  pid_t self_pid;

  GOWL_CHECK_RUNNING ();
  self_pid = getpid ();
  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = (GowlClient *) l->data;
      if (gowl_client_get_pid (c) == self_pid
          && !gowl_client_get_embedded (c))
        return cmacs_gobject_wrap (G_OBJECT (c));
    }
  return Qnil;
}

DEFUN ("gowl-embed-into", Fgowl_embed_into, Sgowl_embed_into,
       2, 2, 0,
       doc: /* Embed CHILD client into PARENT client's scene tree.
CHILD's scene node becomes a child of PARENT's, so it renders
as part of PARENT.  Positions are then parent-relative. */)
  (Lisp_Object child, Lisp_Object parent)
{
  GOWL_CHECK_RUNNING ();
  gowl_compositor_reparent_client_to_client (
    cmacs_gowl_compositor,
    gowl_resolve_client (child),
    gowl_resolve_client (parent));
  return Qnil;
}

DEFUN ("gowl-position-embedded", Fgowl_position_embedded,
       Sgowl_position_embedded, 5, 5, 0,
       doc: /* Position embedded CLIENT at X, Y with size W x H.
Coordinates are relative to the parent scene tree.
Directly sets the scene node position and sends an XDG configure. */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
  GowlClient *c;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);
  c = gowl_resolve_client (client);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_position_embedded (
    cmacs_gowl_compositor, c,
    (gint) XFIXNUM (x), (gint) XFIXNUM (y),
    (gint) XFIXNUM (w), (gint) XFIXNUM (h));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * EMBED VIEW — GTK WIDGET INSIDE EMACS FRAME
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-embed-create-view", Fgowl_embed_create_view,
       Sgowl_embed_create_view, 5, 5, 0,
       doc: /* Create an embed view for CLIENT at X, Y with size W x H.
Adds a GtkDrawingArea to the selected frame and renders the Wayland
client's surface into it.  Coordinates are frame-relative pixels.
The client's compositor scene node is disabled — all rendering goes
through the GTK widget.  Returns t on success. */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
#ifdef HAVE_PGTK
  GowlClient *c;
  struct gowl_embed_view *view;
  struct wlr_surface *surface;
  struct frame *f;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = gowl_resolve_client (client);
  f = SELECTED_FRAME ();

  if (embed_views == NULL)
    embed_views = g_hash_table_new (g_direct_hash, g_direct_equal);

  /* Remove existing view for this client, if any. */
  {
    struct gowl_embed_view *old = g_hash_table_lookup (embed_views, c);
    if (old != NULL)
      {
        g_hash_table_remove (embed_views, c);
        gowl_embed_view_free (old);
      }
  }

  view = g_new0 (struct gowl_embed_view, 1);
  view->client = c;
  view->emacs_frame = f;
  view->view_w = (int) XFIXNUM (w);
  view->view_h = (int) XFIXNUM (h);

  /* Disable the compositor scene node — rendering is via GTK. */
  gowl_client_set_visible (c, FALSE);
  gowl_client_set_embedded (c, TRUE);
  gowl_client_set_border_width (c, 0);

  /* Request the client to render at the widget size by sending a
     configure via gowl_compositor_position_embedded. */
  gowl_compositor_position_embedded (cmacs_gowl_compositor, c,
                                     0, 0, view->view_w, view->view_h);

  /* Create the GtkDrawingArea. */
  view->widget = gtk_drawing_area_new ();
  gtk_widget_set_app_paintable (view->widget, TRUE);
  gtk_widget_add_events (view->widget,
                         GDK_POINTER_MOTION_MASK
                         | GDK_BUTTON_PRESS_MASK
                         | GDK_BUTTON_RELEASE_MASK
                         | GDK_ENTER_NOTIFY_MASK
                         | GDK_LEAVE_NOTIFY_MASK
                         | GDK_SCROLL_MASK
                         | GDK_SMOOTH_SCROLL_MASK
                         | GDK_KEY_PRESS_MASK
                         | GDK_KEY_RELEASE_MASK);
  gtk_widget_set_can_focus (view->widget, TRUE);
  gtk_widget_set_size_request (view->widget, view->view_w, view->view_h);

  g_signal_connect (view->widget, "draw",
                    G_CALLBACK (gowl_embed_view_draw), view);
  g_signal_connect (view->widget, "event",
                    G_CALLBACK (gowl_embed_view_event), view);

  /* Add to Emacs frame's GtkFixed container. */
  gtk_fixed_put (GTK_FIXED (FRAME_GTK_WIDGET (f)),
                 view->widget,
                 (gint) XFIXNUM (x), (gint) XFIXNUM (y));
  gtk_widget_show (view->widget);

  /* Listen for surface commits to capture new frames. */
  surface = gowl_client_get_wlr_surface (c);
  if (surface != NULL)
    {
      view->commit.notify = gowl_embed_view_on_commit;
      wl_signal_add (&surface->events.commit, &view->commit);
      view->destroy.notify = gowl_embed_view_on_surface_destroy;
      wl_signal_add (&surface->events.destroy, &view->destroy);
    }
  else
    {
      wl_list_init (&view->commit.link);
      wl_list_init (&view->destroy.link);
    }

  g_hash_table_insert (embed_views, c, view);
  return Qt;
#else
  error ("gowl-embed-create-view requires PGTK build");
  return Qnil;
#endif
}

DEFUN ("gowl-embed-move-view", Fgowl_embed_move_view,
       Sgowl_embed_move_view, 5, 5, 0,
       doc: /* Reposition embed view for CLIENT to X, Y with size W x H.
Coordinates are frame-relative pixels. */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
#ifdef HAVE_PGTK
  GowlClient *c;
  struct gowl_embed_view *view;
  int nw, nh;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = gowl_resolve_client (client);

  if (embed_views == NULL)
    return Qnil;

  view = g_hash_table_lookup (embed_views, c);
  if (view == NULL || view->widget == NULL)
    return Qnil;

  nw = (int) XFIXNUM (w);
  nh = (int) XFIXNUM (h);

  if (nw <= 0 || nh <= 0)
    {
      /* Hide the widget — do NOT send a 0×0 configure to the client.
         A zero-size XDG configure breaks client rendering permanently.
         The client keeps rendering at its last valid size; the commit
         listener keeps capturing frames so content is ready when we
         show the widget again. */
      gtk_widget_hide (view->widget);
      return Qt;
    }

  view->view_w = nw;
  view->view_h = nh;

  gtk_widget_set_size_request (view->widget, nw, nh);
  gtk_fixed_move (GTK_FIXED (FRAME_GTK_WIDGET (view->emacs_frame)),
                  view->widget,
                  (gint) XFIXNUM (x), (gint) XFIXNUM (y));
  gtk_widget_show (view->widget);
  gtk_widget_queue_allocate (view->widget);

  /* Ask the client to render at the new size. */
  gowl_compositor_position_embedded (cmacs_gowl_compositor, c,
                                     0, 0, nw, nh);

  return Qt;
#else
  return Qnil;
#endif
}

DEFUN ("gowl-embed-destroy-view", Fgowl_embed_destroy_view,
       Sgowl_embed_destroy_view, 1, 1, 0,
       doc: /* Destroy the embed view for CLIENT.
Removes the GtkDrawingArea and frees resources.
The client's compositor scene node remains disabled. */)
  (Lisp_Object client)
{
  GowlClient *c;
  struct gowl_embed_view *view;

  c = gowl_resolve_client (client);

  if (embed_views == NULL)
    return Qnil;

  view = g_hash_table_lookup (embed_views, c);
  if (view != NULL)
    {
      g_hash_table_remove (embed_views, c);
      gowl_embed_view_free (view);
    }
  return Qnil;
}

DEFUN ("gowl-embed-view-p", Fgowl_embed_view_p,
       Sgowl_embed_view_p, 1, 1, 0,
       doc: /* Return t if CLIENT has an active embed view. */)
  (Lisp_Object client)
{
  GowlClient *c = gowl_resolve_client (client);

  if (embed_views == NULL)
    return Qnil;

  return g_hash_table_lookup (embed_views, c) != NULL ? Qt : Qnil;
}

DEFUN ("gowl-embed-focus", Fgowl_embed_focus,
       Sgowl_embed_focus, 1, 1, 0,
       doc: /* Give keyboard focus to embedded CLIENT.
This allows keyboard input to reach the embedded Wayland client.
Use this to re-enter an embedded client after ESC returned
control to Emacs.  CLIENT is a gowl client object.

Returns nil without moving focus while a keyboard-interactive layer
surface (a launcher such as wofi) holds the keyboard -- taking it
would leave that launcher visible on top of the output and deaf. */)
  (Lisp_Object client)
{
  GowlClient *c = gowl_resolve_client (client);
  struct wlr_seat *seat;
  struct wlr_surface *surf;
  struct wlr_keyboard *kb;

  if (cmacs_gowl_compositor == NULL)
    error ("gowl compositor not running");
  if (c == NULL)
    error ("Invalid client");

  if (cmacs_gowl_layer_owns_keyboard ())
    return Qnil;

  seat = gowl_compositor_get_wlr_seat (cmacs_gowl_compositor);
  surf = gowl_client_get_wlr_surface (c);
  if (seat == NULL || surf == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  kb = wlr_seat_get_keyboard (seat);
  if (kb != NULL)
    wlr_seat_keyboard_notify_enter (seat, surf,
                                    kb->keycodes, kb->num_keycodes,
                                    &kb->modifiers);
  else
    wlr_seat_keyboard_notify_enter (seat, surf, NULL, 0, NULL);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-embed-set-visible", Fgowl_embed_set_visible,
       Sgowl_embed_set_visible, 2, 2, 0,
       doc: /* Set the visibility of the embed view for CLIENT.
VISIBLE non-nil shows the widget, nil hides it.
Use this to hide embeds during workspace/tab switches. */)
  (Lisp_Object client, Lisp_Object visible)
{
  GowlClient *c;
  struct gowl_embed_view *view;

  c = gowl_resolve_client (client);

  if (embed_views == NULL)
    return Qnil;

  view = g_hash_table_lookup (embed_views, c);
  if (view == NULL || view->widget == NULL)
    return Qnil;

  if (NILP (visible))
    gtk_widget_hide (view->widget);
  else
    gtk_widget_show (view->widget);

  return visible;
}

DEFUN ("gowl-embed-expect-client", Fgowl_embed_expect_client,
       Sgowl_embed_expect_client, 0, 0, 0,
       doc: /* Tell the compositor to embed the next unmapped client.
When a new Wayland client maps and was not caught by the PID-based
prefloat mechanism (e.g. flatpak, sandbox launchers), the compositor
will force-embed it instead of tiling it normally.  The counter is
decremented on each match, so call once per expected embed. */)
  (void)
{
  cmacs_embed_pending_count++;
  return Qt;
}


/* ══════════════════════════════════════════════════════════════════════
 * MONITOR MANAGEMENT
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-list-monitors", Fgowl_list_monitors, Sgowl_list_monitors,
       0, 0, 0,
       doc: /* Return a list of connected monitor objects. */)
  (void)
{
  GList *monitors, *l;
  Lisp_Object result = Qnil;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    result = Fcons (cmacs_gobject_wrap (G_OBJECT (l->data)), result);

  return Fnreverse (result);
}

DEFUN ("gowl-monitor-count", Fgowl_monitor_count, Sgowl_monitor_count,
       0, 0, 0,
       doc: /* Return the number of connected monitors. */)
  (void)
{
  if (cmacs_gowl_compositor == NULL)
    return make_fixnum (0);
  return make_fixnum (
    (EMACS_INT)gowl_compositor_get_monitor_count (cmacs_gowl_compositor));
}

DEFUN ("gowl-focused-monitor", Fgowl_focused_monitor,
       Sgowl_focused_monitor, 0, 0, 0,
       doc: /* Return the currently focused monitor, or nil. */)
  (void)
{
  GowlMonitor *mon;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  mon = gowl_get_focused_monitor ();
  if (mon == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (mon));
}

DEFUN ("gowl-find-monitor", Fgowl_find_monitor, Sgowl_find_monitor,
       1, 1, 0,
       doc: /* Return the monitor named NAME, or nil if not found.
NAME is a string such as "eDP-1" or "HDMI-A-1". */)
  (Lisp_Object name)
{
  GList *monitors, *l;
  const gchar *target;

  CHECK_STRING (name);
  GOWL_CHECK_RUNNING ();

  target = SSDATA (name);
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    {
      GowlMonitor *mon = GOWL_MONITOR (l->data);
      const gchar *n = gowl_monitor_get_name (mon);
      if (n != NULL && strcmp (n, target) == 0)
        return cmacs_gobject_wrap (G_OBJECT (mon));
    }
  return Qnil;
}

DEFUN ("gowl-monitor-info", Fgowl_monitor_info, Sgowl_monitor_info,
       0, 1, 0,
       doc: /* Return an alist of MONITOR properties.
Keys: name, geometry, mfact, nmaster, tags, layout-symbol,
enabled, scale, transform, current-mode, modes.
MONITOR defaults to the focused monitor. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  gint x, y, w, h;
  Lisp_Object result, modes_list, cur_mode_val;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  gowl_monitor_get_geometry (mon, &x, &y, &w, &h);

  /* Build modes list and current-mode under mutex (reads wlr_output). */
  modes_list = Qnil;
  cur_mode_val = Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  {
    GList *modes, *ml;
    GowlOutputMode *cur;
    gboolean enabled;
    gdouble scale;
    gint transform;

    modes = gowl_monitor_get_modes (mon);
    for (ml = modes; ml != NULL; ml = ml->next)
      {
        GowlOutputMode *m = (GowlOutputMode *)ml->data;
        modes_list = Fcons (list3 (make_fixnum (m->width),
                                   make_fixnum (m->height),
                                   make_fixnum (m->refresh_mhz)),
                            modes_list);
        gowl_output_mode_free (m);
      }
    g_list_free (modes);
    modes_list = Fnreverse (modes_list);

    cur = gowl_monitor_get_current_mode (mon);
    if (cur != NULL)
      {
        cur_mode_val = list3 (make_fixnum (cur->width),
                              make_fixnum (cur->height),
                              make_fixnum (cur->refresh_mhz));
        gowl_output_mode_free (cur);
      }

    enabled = gowl_monitor_get_enabled (mon);
    scale = gowl_monitor_get_scale (mon);
    transform = gowl_monitor_get_transform (mon);

    result = list (
      Fcons (intern_c_string ("name"),
             build_string (gowl_monitor_get_name (mon) ? : "")),
      Fcons (intern_c_string ("geometry"),
             list4 (make_fixnum (x), make_fixnum (y),
                    make_fixnum (w), make_fixnum (h))),
      Fcons (intern_c_string ("mfact"),
             make_float (gowl_monitor_get_mfact (mon))),
      Fcons (intern_c_string ("nmaster"),
             make_fixnum (gowl_monitor_get_nmaster (mon))),
      Fcons (intern_c_string ("tags"),
             make_fixnum ((EMACS_INT)gowl_monitor_get_tags (mon))),
      Fcons (intern_c_string ("layout-symbol"),
             gowl_monitor_get_layout_symbol (mon)
               ? build_string (gowl_monitor_get_layout_symbol (mon))
               : Qnil),
      Fcons (intern_c_string ("enabled"), enabled ? Qt : Qnil),
      Fcons (intern_c_string ("scale"), make_float (scale)),
      Fcons (intern_c_string ("transform"), make_fixnum (transform)),
      Fcons (intern_c_string ("current-mode"), cur_mode_val),
      Fcons (intern_c_string ("modes"), modes_list));
  }
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return result;
}

DEFUN ("gowl-monitor-modes", Fgowl_monitor_modes,
       Sgowl_monitor_modes, 0, 1, 0,
       doc: /* Return available modes for MONITOR as a list of triples.
Each element is (WIDTH HEIGHT REFRESH-MHZ).
MONITOR defaults to the focused monitor. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  GList *modes, *l;
  Lisp_Object result = Qnil;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  modes = gowl_monitor_get_modes (mon);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  for (l = modes; l != NULL; l = l->next)
    {
      GowlOutputMode *m = (GowlOutputMode *)l->data;
      result = Fcons (list3 (make_fixnum (m->width),
                             make_fixnum (m->height),
                             make_fixnum (m->refresh_mhz)),
                      result);
      gowl_output_mode_free (m);
    }
  g_list_free (modes);

  return Fnreverse (result);
}

DEFUN ("gowl-monitor-current-mode", Fgowl_monitor_current_mode,
       Sgowl_monitor_current_mode, 0, 1, 0,
       doc: /* Return current mode for MONITOR as (WIDTH HEIGHT REFRESH-MHZ).
Returns nil if no mode is set.  MONITOR defaults to focused. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  GowlOutputMode *cur;
  Lisp_Object result;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  cur = gowl_monitor_get_current_mode (mon);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  if (cur == NULL)
    return Qnil;

  result = list3 (make_fixnum (cur->width),
                  make_fixnum (cur->height),
                  make_fixnum (cur->refresh_mhz));
  gowl_output_mode_free (cur);
  return result;
}

DEFUN ("gowl-set-monitor-mode", Fgowl_set_monitor_mode,
       Sgowl_set_monitor_mode, 3, 4, 0,
       doc: /* Set MONITOR output mode to WIDTH x HEIGHT at REFRESH mHz.
Returns t on success, nil on failure.  MONITOR defaults to focused. */)
  (Lisp_Object width, Lisp_Object height, Lisp_Object refresh,
   Lisp_Object monitor)
{
  GowlMonitor *mon;
  gboolean ok;

  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);
  CHECK_FIXNUM (refresh);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ok = gowl_monitor_set_mode (mon, (gint)XFIXNUM (width),
                               (gint)XFIXNUM (height),
                               (gint)XFIXNUM (refresh));
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return ok ? Qt : Qnil;
}

DEFUN ("gowl-monitor-position", Fgowl_monitor_position,
       Sgowl_monitor_position, 0, 1, 0,
       doc: /* Return MONITOR position as (X . Y) cons cell.
MONITOR defaults to focused. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  gint x, y;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  gowl_monitor_get_position (mon, &x, &y);
  return Fcons (make_fixnum (x), make_fixnum (y));
}

DEFUN ("gowl-set-monitor-position", Fgowl_set_monitor_position,
       Sgowl_set_monitor_position, 2, 3, 0,
       doc: /* Set MONITOR position to X, Y in layout space.
Returns t on success, nil on failure.  MONITOR defaults to focused. */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object monitor)
{
  GowlMonitor *mon;
  gboolean ok;

  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ok = gowl_monitor_set_position (mon, (gint)XFIXNUM (x),
                                   (gint)XFIXNUM (y));
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return ok ? Qt : Qnil;
}

DEFUN ("gowl-monitor-enabled-p", Fgowl_monitor_enabled_p,
       Sgowl_monitor_enabled_p, 0, 1, 0,
       doc: /* Return t if MONITOR is enabled, nil otherwise.
MONITOR defaults to focused. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  gboolean enabled;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  enabled = gowl_monitor_get_enabled (mon);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return enabled ? Qt : Qnil;
}

DEFUN ("gowl-set-monitor-enabled", Fgowl_set_monitor_enabled,
       Sgowl_set_monitor_enabled, 1, 2, 0,
       doc: /* Enable or disable MONITOR according to ENABLED.
Returns t on success, nil on failure.  MONITOR defaults to focused. */)
  (Lisp_Object enabled, Lisp_Object monitor)
{
  GowlMonitor *mon;
  gboolean ok;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ok = gowl_monitor_set_enabled (mon, !NILP (enabled));
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return ok ? Qt : Qnil;
}

DEFUN ("gowl-monitor-scale", Fgowl_monitor_scale,
       Sgowl_monitor_scale, 0, 1, 0,
       doc: /* Return the scale factor for MONITOR as a float.
MONITOR defaults to focused. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  gdouble scale;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  scale = gowl_monitor_get_scale (mon);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return make_float (scale);
}

DEFUN ("gowl-set-monitor-scale", Fgowl_set_monitor_scale,
       Sgowl_set_monitor_scale, 1, 2, 0,
       doc: /* Set MONITOR scale factor to SCALE.
SCALE is a number (e.g. 1.0, 1.5, 2.0).
Returns t on success, nil on failure.  MONITOR defaults to focused. */)
  (Lisp_Object scale, Lisp_Object monitor)
{
  GowlMonitor *mon;
  gboolean ok;

  CHECK_NUMBER (scale);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ok = gowl_monitor_set_scale (mon, XFLOATINT (scale));
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return ok ? Qt : Qnil;
}

DEFUN ("gowl-monitor-transform", Fgowl_monitor_transform,
       Sgowl_monitor_transform, 0, 1, 0,
       doc: /* Return the transform for MONITOR as a symbol.
Possible values: normal, 90, 180, 270, flipped,
flipped-90, flipped-180, flipped-270.
MONITOR defaults to focused. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  gint xform;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  xform = gowl_monitor_get_transform (mon);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  switch (xform)
    {
    case 0: return Qnormal;
    case 1: return Q90;
    case 2: return Q180;
    case 3: return Q270;
    case 4: return Qflipped;
    case 5: return Qflipped_90;
    case 6: return Qflipped_180;
    case 7: return Qflipped_270;
    default: return make_fixnum (xform);
    }
}

DEFUN ("gowl-set-monitor-transform", Fgowl_set_monitor_transform,
       Sgowl_set_monitor_transform, 1, 2, 0,
       doc: /* Set MONITOR transform to TRANSFORM.
TRANSFORM is an integer 0-7 or a symbol: normal, 90, 180, 270,
flipped, flipped-90, flipped-180, flipped-270.
Returns t on success, nil on failure.  MONITOR defaults to focused. */)
  (Lisp_Object transform, Lisp_Object monitor)
{
  GowlMonitor *mon;
  gint xform;
  gboolean ok;

  GOWL_CHECK_RUNNING ();

  if (FIXNUMP (transform))
    xform = (gint)XFIXNUM (transform);
  else if (EQ (transform, Qnormal))
    xform = 0;
  else if (EQ (transform, Q90))
    xform = 1;
  else if (EQ (transform, Q180))
    xform = 2;
  else if (EQ (transform, Q270))
    xform = 3;
  else if (EQ (transform, Qflipped))
    xform = 4;
  else if (EQ (transform, Qflipped_90))
    xform = 5;
  else if (EQ (transform, Qflipped_180))
    xform = 6;
  else if (EQ (transform, Qflipped_270))
    xform = 7;
  else
    error ("Invalid transform: must be integer 0-7 or symbol");

  if (xform < 0 || xform > 7)
    error ("Transform must be between 0 and 7");

  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ok = gowl_monitor_set_transform (mon, xform);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return ok ? Qt : Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * TAG OPERATIONS
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-view-tags", Fgowl_view_tags, Sgowl_view_tags, 1, 2, 0,
       doc: /* Switch tag view to TAGMASK on MONITOR.
TAGMASK is an integer bitmask.  MONITOR defaults to focused.
Performs a full dwm view(): shows/hides clients, selects the
monitor, focuses its top client, and re-tiles. */)
  (Lisp_Object tagmask, Lisp_Object monitor)
{
  GowlMonitor *mon;

  CHECK_FIXNAT (tagmask);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      gowl_compositor_view_tags (cmacs_gowl_compositor, mon,
                                 (guint32)XFIXNAT (tagmask));
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }

  return Qnil;
}

DEFUN ("gowl-toggle-tag-view", Fgowl_toggle_tag_view,
       Sgowl_toggle_tag_view, 1, 2, 0,
       doc: /* Toggle visibility of TAG on MONITOR.
TAG is a 0-based tag index.  MONITOR defaults to focused. */)
  (Lisp_Object tag, Lisp_Object monitor)
{
  GowlMonitor *mon;

  CHECK_FIXNAT (tag);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    gowl_monitor_toggle_tag (mon, (guint32)XFIXNAT (tag));

  return Qnil;
}

DEFUN ("gowl-toggle-client-tag", Fgowl_toggle_client_tag,
       Sgowl_toggle_client_tag, 2, 2, 0,
       doc: /* Toggle TAG bit on CLIENT's tags.
TAG is a 0-based index. */)
  (Lisp_Object client, Lisp_Object tag)
{
  GowlClient *c;
  guint32 tags, bit;

  CHECK_FIXNAT (tag);
  c = gowl_resolve_client (client);

  bit = 1u << (guint32)XFIXNAT (tag);
  tags = gowl_client_get_tags (c);
  gowl_client_set_tags (c, tags ^ bit);

  return Qnil;
}

DEFUN ("gowl-tag-info", Fgowl_tag_info, Sgowl_tag_info, 0, 1, 0,
       doc: /* Return tag info for MONITOR as an alist.
Keys: active (visible tags bitmask), count (total tags from config). */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  GowlConfig *config;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  config = gowl_compositor_get_config (cmacs_gowl_compositor);

  return list2 (
    Fcons (intern_c_string ("active"),
           mon ? make_fixnum ((EMACS_INT)gowl_monitor_get_tags (mon))
               : make_fixnum (0)),
    Fcons (intern_c_string ("count"),
           config ? make_fixnum (gowl_config_get_tag_count (config))
                  : make_fixnum (9)));
}


/* ══════════════════════════════════════════════════════════════════════
 * LAYOUT CONTROL
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-set-mfact", Fgowl_set_mfact, Sgowl_set_mfact, 1, 2, 0,
       doc: /* Set master area factor to MFACT on MONITOR.
MFACT is a float between 0.05 and 0.95. */)
  (Lisp_Object mfact, Lisp_Object monitor)
{
  GowlMonitor *mon;
  double val;

  CHECK_NUMBER (mfact);
  GOWL_CHECK_RUNNING ();

  val = XFLOATINT (mfact);
  if (val < 0.05 || val > 0.95)
    error ("mfact must be between 0.05 and 0.95");

  mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    gowl_monitor_set_mfact (mon, val);

  return Qnil;
}

DEFUN ("gowl-get-mfact", Fgowl_get_mfact, Sgowl_get_mfact, 0, 1, 0,
       doc: /* Return the master area factor for MONITOR. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  return make_float (gowl_monitor_get_mfact (mon));
}

DEFUN ("gowl-set-nmaster", Fgowl_set_nmaster, Sgowl_set_nmaster,
       1, 2, 0,
       doc: /* Set number of master windows to N on MONITOR. */)
  (Lisp_Object n, Lisp_Object monitor)
{
  GowlMonitor *mon;

  CHECK_FIXNUM (n);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    gowl_monitor_set_nmaster (mon, (gint)XFIXNUM (n));

  return Qnil;
}

DEFUN ("gowl-get-nmaster", Fgowl_get_nmaster, Sgowl_get_nmaster,
       0, 1, 0,
       doc: /* Return the number of master windows for MONITOR. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  return make_fixnum (gowl_monitor_get_nmaster (mon));
}

DEFUN ("gowl-set-vsplit", Fgowl_set_vsplit, Sgowl_set_vsplit, 1, 2, 0,
       doc: /* Enable vsplit on MONITOR when VSPLIT is non-nil.
Vsplit puts the master row on top and the stack row on the bottom
(the existing window stays on top, new windows underneath).  nil
restores the normal left/right split.  Re-arranges immediately. */)
  (Lisp_Object vsplit, Lisp_Object monitor)
{
  GowlMonitor *mon;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      gowl_monitor_set_vsplit (mon, !NILP (vsplit));
      gowl_compositor_arrange (cmacs_gowl_compositor, mon);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }
  return Qnil;
}

DEFUN ("gowl-get-vsplit", Fgowl_get_vsplit, Sgowl_get_vsplit, 0, 1, 0,
       doc: /* Return non-nil if MONITOR uses the vsplit tile orientation. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  return gowl_monitor_get_vsplit (mon) ? Qt : Qnil;
}

DEFUN ("gowl-get-layout", Fgowl_get_layout, Sgowl_get_layout, 0, 1, 0,
       doc: /* Return the current layout symbol string for MONITOR. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  const gchar *sym;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  sym = gowl_monitor_get_layout_symbol (mon);
  return sym ? build_string (sym) : Qnil;
}

DEFUN ("gowl-set-layout", Fgowl_set_layout, Sgowl_set_layout, 1, 2, 0,
       doc: /* Set LAYOUT on MONITOR.
LAYOUT is a layout name: \"tile\", \"monocle\", \"float\",
\"scrolling\", or any layout a loaded module registered.  See
`gowl-list-layouts'.  MONITOR is currently ignored; the layout applies
to the focused monitor.

Returns t when LAYOUT named a registered layout, nil otherwise.

This used to look for a keybind bound to the requested layout and
dispatch it through the MODULE key path -- which serves module
keybinds, not compositor actions -- and, when no such keybind existed,
build an eval expression and immediately free it without running it.
So it worked only by accident, and reported success either way. */)
  (Lisp_Object layout, Lisp_Object monitor)
{
  CHECK_STRING (layout);
  GOWL_CHECK_RUNNING ();

  (void) monitor;  /* the layout applies to the focused monitor */

  return gowl_layout_set (cmacs_gowl_compositor, NULL, SSDATA (layout))
         ? Qt : Qnil;
}

DEFUN ("gowl-list-layouts", Fgowl_list_layouts, Sgowl_list_layouts,
       0, 0, 0,
       doc: /* Return the registered layout names, as a list of strings.
Includes the built-ins and any layout a loaded module registered --- a
module layout is selectable by name exactly like a built-in. */)
  (void)
{
  GList *names, *l;
  Lisp_Object result = Qnil;

  GOWL_CHECK_RUNNING ();

  names = gowl_layout_list (cmacs_gowl_compositor);
  for (l = names; l != NULL; l = l->next)
    result = Fcons (build_string ((const char *) l->data), result);
  g_list_free (names);

  return Fnreverse (result);
}

DEFUN ("gowl-cycle-layout", Fgowl_cycle_layout, Sgowl_cycle_layout,
       0, 1, 0,
       doc: /* Move to the next layout, returning its name.
With STEP negative, move backwards.  Wraps at both ends. */)
  (Lisp_Object step)
{
  const gchar *name;
  gint n = 1;

  GOWL_CHECK_RUNNING ();

  if (FIXNUMP (step))
    n = (gint) XFIXNUM (step);

  name = gowl_layout_cycle (cmacs_gowl_compositor, NULL, n);
  return name ? build_string (name) : Qnil;
}

DEFUN ("gowl-scroll-by", Fgowl_scroll_by, Sgowl_scroll_by, 1, 1, 0,
       doc: /* Scroll the column strip by DX pixels.
Only meaningful in the scrolling layout.  Clamping happens in the
layout, so pushing past either end is harmless. */)
  (Lisp_Object dx)
{
  CHECK_FIXNUM (dx);
  GOWL_CHECK_RUNNING ();

  gowl_compositor_scroll_by (cmacs_gowl_compositor, NULL,
                             (gint) XFIXNUM (dx));
  return Qt;
}

DEFUN ("gowl-add-keybind", Fgowl_add_keybind, Sgowl_add_keybind,
       2, 4, 0,
       doc: /* Add a keybind.  KEY is a string like \"Super+Return\".
ACTION is a symbol naming a gowl action, or its integer value.  The
symbol names are gowl's own action nicks -- `spawn', `kill-client',
`toggle-float', `toggle-fullscreen', `focus-stack', `focus-monitor',
`tag-view', `tag-set', `tag-toggle-view', `tag-toggle',
`move-to-monitor', `set-mfact', `inc-nmaster', `set-layout',
`cycle-layout', `set-split', `zoom', `quit', `reload-config',
`ipc-command', `lock', `custom' and `none' -- resolved from the
GowlAction enum itself, so a new action in gowl works here with no
change.  Underscores are accepted in place of hyphens.

Optional ARG is a string argument for the action, e.g. the command for
`spawn' or the Elisp form for `custom'.

Optional DESC is a human-readable description of what the bind does.
It never affects dispatch; `cmacs-gowl-describe-keybinds' and gowl's
MCP `list_keybinds' render it.

KEY is resolved with gowl_keybind_parse, so it accepts any keysym name
xkbcommon knows -- including the modifierless media keys, whose names
all begin \"XF86\".  */)
  (Lisp_Object key, Lisp_Object action, Lisp_Object arg, Lisp_Object desc)
{
  GowlConfig *config;
  guint modifiers, keysym;
  gint action_val;
  const gchar *arg_str = NULL;
  const gchar *desc_str = NULL;

  CHECK_STRING (key);
  GOWL_CHECK_RUNNING ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    error ("No gowl config loaded");

  if (!gowl_keybind_parse (SSDATA (key), &modifiers, &keysym))
    error ("Invalid key string: %s", SSDATA (key));

  if (FIXNUMP (action))
    action_val = (gint)XFIXNUM (action);
  else if (SYMBOLP (action))
    {
      if (!cmacs_gowl_action_from_name (SSDATA (SYMBOL_NAME (action)),
                                        &action_val))
        error ("Unknown action: %s", SSDATA (SYMBOL_NAME (action)));
    }
  else
    error ("ACTION must be an integer or symbol");

  if (STRINGP (arg))
    arg_str = SSDATA (arg);
  if (STRINGP (desc))
    desc_str = SSDATA (desc);

  gowl_config_add_keybind_full (config, modifiers, keysym,
                                 action_val, arg_str, desc_str);
  return Qt;
}

DEFUN ("gowl-list-keybinds", Fgowl_list_keybinds, Sgowl_list_keybinds,
       0, 0, 0,
       doc: /* Return a list of keybind alists.
Each alist has keys: key, action, arg, desc.

`action' is the action's symbol -- `spawn', `kill-client', ... -- taken
from gowl's own GowlAction enum, so it reads the same way it is written
in `gowl-add-keybind' and in a YAML config.  An action value gowl does
not know (only reachable by passing an integer to `gowl-add-keybind')
comes back as the integer instead.

`desc' is the bind's description, or nil when it was registered without
one.  `cmacs-gowl-describe-keybinds' renders this list.  */)
  (void)
{
  GowlConfig *config;
  GArray *keybinds;
  Lisp_Object result = Qnil;
  guint i;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;

  keybinds = gowl_config_get_keybinds (config);
  for (i = 0; i < keybinds->len; i++)
    {
      GowlKeybindEntry *kb = &g_array_index (keybinds, GowlKeybindEntry, i);
      gchar *key_str = gowl_keybind_to_string (kb->modifiers, kb->keysym);
      const gchar *action_nick = cmacs_gowl_action_to_name (kb->action);
      Lisp_Object entry;

      entry = list4 (
        Fcons (intern_c_string ("key"),
               build_string (key_str ? key_str : "")),
        /* A symbol when gowl knows the value, else the raw integer --
           losing an unrecognised action entirely would be worse than
           showing a number the caller can look up. */
        Fcons (intern_c_string ("action"),
               action_nick ? intern (action_nick) : make_fixnum (kb->action)),
        Fcons (intern_c_string ("arg"),
               kb->arg ? build_string (kb->arg) : Qnil),
        Fcons (intern_c_string ("desc"),
               kb->desc ? build_string (kb->desc) : Qnil));

      g_free (key_str);
      result = Fcons (entry, result);
    }

  return Fnreverse (result);
}

DEFUN ("gowl-run-keybind", Fgowl_run_keybind, Sgowl_run_keybind,
       1, 1, 0,
       doc: /* Run the action bound to KEY, as if the key had been pressed.
KEY is a string like \"Super+Return\" (parsed with gowl_keybind_parse).

This is the compositor's own keybind dispatch, so a `spawn' bind
launches its command and a `custom' bind evaluates its Elisp form.
Note that `gowl-send-key' does NOT do this: injected keys go to the
focused client and never consult the keybind table.

Returns t if a bind matched, nil otherwise. */)
  (Lisp_Object key)
{
  guint modifiers, keysym;

  CHECK_STRING (key);
  GOWL_CHECK_RUNNING ();

  if (!gowl_keybind_parse (SSDATA (key), &modifiers, &keysym))
    error ("Invalid key string: %s", SSDATA (key));

  return gowl_compositor_dispatch_keybind (cmacs_gowl_compositor,
                                           modifiers, keysym)
         ? Qt : Qnil;
}

DEFUN ("gowl-remove-keybind", Fgowl_remove_keybind, Sgowl_remove_keybind,
       1, 1, 0,
       doc: /* Remove every keybind whose key combo is KEY.
KEY is a string like \"Super+p\" (parsed with gowl_keybind_parse).
Action and arg are not matched, so all binds for that combo are
removed -- use this before `gowl-add-keybind' to make a freshly
installed bind authoritative, since gowl dispatches the first
matching entry and an older duplicate would otherwise shadow it.
Returns the number of keybinds removed (an integer). */)
  (Lisp_Object key)
{
  GowlConfig *config;
  guint modifiers, keysym;
  guint removed;

  CHECK_STRING (key);
  GOWL_CHECK_RUNNING ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    error ("No gowl config loaded");

  if (!gowl_keybind_parse (SSDATA (key), &modifiers, &keysym))
    error ("Invalid key string: %s", SSDATA (key));

  removed = gowl_config_remove_keybind (config, modifiers, keysym);
  return make_fixnum ((gint)removed);
}

DEFUN ("gowl-clear-keybinds", Fgowl_clear_keybinds, Sgowl_clear_keybinds,
       0, 0, 0,
       doc: /* Remove every keybind from the gowl config. */)
  (void)
{
  GowlConfig *config;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;
  gowl_config_clear_keybinds (config);
  return Qt;
}


/* ══════════════════════════════════════════════════════════════════════
 * WINDOW RULES
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-add-rule", Fgowl_add_rule, Sgowl_add_rule, 0, 5, 0,
       doc: /* Add a window placement rule.
APP-ID and TITLE are glob patterns (strings or nil).
TAGS is a bitmask, FLOATING is a boolean, MONITOR is an integer (-1 for any). */)
  (Lisp_Object app_id, Lisp_Object title, Lisp_Object tags,
   Lisp_Object floating, Lisp_Object monitor_idx)
{
  GowlConfig *config;
  const gchar *app_str = NULL;
  const gchar *title_str = NULL;
  guint32 tags_val = 0;
  gboolean float_val = FALSE;
  gint mon_val = -1;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    error ("No gowl config loaded");

  if (STRINGP (app_id))   app_str = SSDATA (app_id);
  if (STRINGP (title))    title_str = SSDATA (title);
  if (FIXNATP (tags))     tags_val = (guint32)XFIXNAT (tags);
  if (!NILP (floating))   float_val = TRUE;
  if (FIXNUMP (monitor_idx)) mon_val = (gint)XFIXNUM (monitor_idx);

  gowl_config_add_rule (config, app_str, title_str,
                         tags_val, float_val, mon_val);
  return Qt;
}

DEFUN ("gowl-add-rule-full", Fgowl_add_rule_full, Sgowl_add_rule_full,
       0, 8, 0,
       doc: /* Add a window placement rule with every tunable field.
APP-ID and TITLE are pattern strings (or nil).  TAGS is a bitmask.
FLOATING and REGEX are booleans.  MONITOR, WIDTH, HEIGHT are integers
(MONITOR -1 for any; WIDTH/HEIGHT 0 to keep natural size).  When
REGEX is non-nil, APP-ID and TITLE are compiled as PCRE regexes
(GRegex) instead of being matched as shell globs.

The rule's `center' flag (center floated match on target monitor)
is always true from this entry point.  Use a YAML `rules:' section
with `center: false' to opt out, or call `gowl-add-rule' for the
minimal legacy form.  */)
  (Lisp_Object app_id, Lisp_Object title, Lisp_Object tags,
   Lisp_Object floating, Lisp_Object monitor_idx, Lisp_Object width,
   Lisp_Object height, Lisp_Object regex)
{
  GowlConfig *config;
  const gchar *app_str = NULL;
  const gchar *title_str = NULL;
  guint32 tags_val = 0;
  gboolean float_val = FALSE;
  gint mon_val = -1;
  gint width_val = 0;
  gint height_val = 0;
  gboolean regex_val = FALSE;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    error ("No gowl config loaded");

  if (STRINGP (app_id))       app_str = SSDATA (app_id);
  if (STRINGP (title))        title_str = SSDATA (title);
  if (FIXNATP (tags))         tags_val = (guint32)XFIXNAT (tags);
  if (!NILP (floating))       float_val = TRUE;
  if (FIXNUMP (monitor_idx))  mon_val = (gint)XFIXNUM (monitor_idx);
  if (FIXNATP (width))        width_val = (gint)XFIXNAT (width);
  if (FIXNATP (height))       height_val = (gint)XFIXNAT (height);
  if (!NILP (regex))          regex_val = TRUE;

  gowl_config_add_rule_full (config, app_str, title_str, tags_val,
                              float_val, mon_val, width_val,
                              height_val, TRUE, regex_val);
  return Qt;
}

DEFUN ("gowl-remove-rule", Fgowl_remove_rule, Sgowl_remove_rule, 0, 2, 0,
       doc: /* Remove the first window rule matching APP-ID and TITLE literally.
Both arguments are strings or nil; nil matches a rule's nil field.
Returns t if a rule was removed, nil otherwise. */)
  (Lisp_Object app_id, Lisp_Object title)
{
  GowlConfig *config;
  const gchar *app_str = NULL;
  const gchar *title_str = NULL;
  guint removed;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;

  if (STRINGP (app_id))  app_str = SSDATA (app_id);
  if (STRINGP (title))   title_str = SSDATA (title);

  removed = gowl_config_remove_rule (config, app_str, title_str);
  return removed > 0 ? Qt : Qnil;
}

DEFUN ("gowl-clear-rules", Fgowl_clear_rules, Sgowl_clear_rules, 0, 0, 0,
       doc: /* Remove every window rule from the gowl config. */)
  (void)
{
  GowlConfig *config;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;
  gowl_config_clear_rules (config);
  return Qt;
}

DEFUN ("gowl-list-rules", Fgowl_list_rules, Sgowl_list_rules, 0, 0, 0,
       doc: /* Return a list of window rule alists.
Each alist contains: app-id, title, tags, floating, monitor, width,
height, center, regex. */)
  (void)
{
  GowlConfig *config;
  GPtrArray *rules;
  Lisp_Object result = Qnil;
  guint i;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;

  rules = gowl_config_get_rules (config);
  for (i = 0; i < rules->len; i++)
    {
      GowlRuleEntry *r = g_ptr_array_index (rules, i);
      Lisp_Object entry;

      entry = Fcons (Fcons (intern_c_string ("app-id"),
                             r->app_id ? build_string (r->app_id) : Qnil),
                     Fcons (Fcons (intern_c_string ("title"),
                             r->title ? build_string (r->title) : Qnil),
                     Fcons (Fcons (intern_c_string ("tags"),
                             make_fixnum ((EMACS_INT)r->tags)),
                     Fcons (Fcons (intern_c_string ("floating"),
                             r->floating ? Qt : Qnil),
                     Fcons (Fcons (intern_c_string ("monitor"),
                             make_fixnum (r->monitor)),
                     Fcons (Fcons (intern_c_string ("width"),
                             make_fixnum (r->width)),
                     Fcons (Fcons (intern_c_string ("height"),
                             make_fixnum (r->height)),
                     Fcons (Fcons (intern_c_string ("center"),
                             r->center ? Qt : Qnil),
                     Fcons (Fcons (intern_c_string ("regex"),
                             r->regex_mode ? Qt : Qnil),
                            Qnil)))))))));

      result = Fcons (entry, result);
    }

  return Fnreverse (result);
}

DEFUN ("gowl-float-toggle", Fgowl_float_toggle, Sgowl_float_toggle,
       0, 0, 0,
       doc: /* Toggle the floating state of the currently focused client.
Reparents the scene node to the FLOAT or TILE layer and re-runs
the layout so neighbouring tiled clients reclaim or yield space.

Returns t if the client was toggled, nil if no client is
focused, and signals an error if the focused client is embedded
(use `cmacs-gowl-embed-release' to free an embedded client). */)
  (void)
{
  GowlClient *c;

  GOWL_CHECK_RUNNING ();
  c = gowl_compositor_get_focused_client (cmacs_gowl_compositor);
  if (c == NULL)
    return Qnil;
  if (gowl_client_get_embedded (c))
    error ("gowl: focused client is embedded; release it first");
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_compositor_set_floating (cmacs_gowl_compositor, c,
                                 !gowl_client_get_floating (c));
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-module-dispatch-key", Fgowl_module_dispatch_key,
       Sgowl_module_dispatch_key, 2, 2, 0,
       doc: /* Synthetically dispatch a key event to all keybind-handler modules.
MODIFIERS is an integer bitmask (Shift=1, Ctrl=4, Alt=8, Super=64).
KEYSYM is the XKB keysym as an integer.  Returns t if any module
consumed the event, nil otherwise.  Useful for testing the
`windowrules' and `dropdown' module keybinds from elisp without
having to press the real key combination.

Example — toggle the first dropdown bound to Super+grave (keysym
0xFE50 on many layouts; use `xev' to find the right one for yours):

    (gowl-module-dispatch-key 64 #x0060)  ; Super + ` (grave) */)
  (Lisp_Object modifiers, Lisp_Object keysym)
{
  GowlModuleManager *mgr;
  guint mods;
  guint sym;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (modifiers);
  CHECK_FIXNAT (keysym);
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;
  mods = (guint)XFIXNAT (modifiers);
  sym  = (guint)XFIXNAT (keysym);
  return gowl_module_manager_dispatch_key (mgr, mods, sym, TRUE)
           ? Qt : Qnil;
}

/* ══════════════════════════════════════════════════════════════════════
 * DROPDOWNS (Guake-style toggleable windows)
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-add-dropdown", Fgowl_add_dropdown, Sgowl_add_dropdown,
       3, 8, 0,
       doc: /* Add a dropdown entry to the gowl config.
NAME is a unique string identifier.  SPAWN-CMD is the shell command
spawned on first toggle.  KEYBIND is a keybind string parsed via
`gowl-keybind-parse' (e.g. \"Super+grave\"), or nil for elisp-only
toggling.  WIDTH-PCT and HEIGHT-PCT are fractions (0.0–1.0) of the
target monitor; WIDTH and HEIGHT are absolute pixel sizes and take
precedence when non-zero.  ANCHOR is a symbol: `top', `bottom',
`left', or `right'.  */)
  (Lisp_Object name, Lisp_Object spawn_cmd, Lisp_Object keybind,
   Lisp_Object width_pct, Lisp_Object height_pct,
   Lisp_Object width, Lisp_Object height, Lisp_Object anchor)
{
  GowlConfig *config;
  const gchar *keybind_str = NULL;
  gdouble wp = 1.0;
  gdouble hp = 0.4;
  gint    wa = 0;
  gint    ha = 0;
  gint    anc = 0;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (name);
  CHECK_STRING (spawn_cmd);
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    error ("No gowl config loaded");

  if (STRINGP (keybind))  keybind_str = SSDATA (keybind);
  if (FLOATP (width_pct)) wp = XFLOAT_DATA (width_pct);
  else if (FIXNUMP (width_pct)) wp = (gdouble)XFIXNUM (width_pct);
  if (FLOATP (height_pct)) hp = XFLOAT_DATA (height_pct);
  else if (FIXNUMP (height_pct)) hp = (gdouble)XFIXNUM (height_pct);
  if (FIXNATP (width))    wa = (gint)XFIXNAT (width);
  if (FIXNATP (height))   ha = (gint)XFIXNAT (height);

  if (EQ (anchor, intern_c_string ("bottom")))     anc = 1;
  else if (EQ (anchor, intern_c_string ("left")))  anc = 2;
  else if (EQ (anchor, intern_c_string ("right"))) anc = 3;
  else                                              anc = 0;

  gowl_config_add_dropdown (config, SSDATA (name), SSDATA (spawn_cmd),
                             keybind_str, wp, hp, wa, ha, anc);
  return Qt;
}

DEFUN ("gowl-remove-dropdown", Fgowl_remove_dropdown,
       Sgowl_remove_dropdown, 1, 1, 0,
       doc: /* Remove the dropdown entry named NAME. */)
  (Lisp_Object name)
{
  GowlConfig *config;
  guint removed;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (name);
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;
  removed = gowl_config_remove_dropdown (config, SSDATA (name));
  return removed > 0 ? Qt : Qnil;
}

/* Look up the active dropdown module and return it as the
   #GowlDropdownProvider interface.  Returns NULL if the module
   is not loaded, not active, or does not implement the
   interface. */
static GowlDropdownProvider *
cmacs_gowl_find_dropdown_provider (void)
{
  GowlModuleManager *mgr;
  GowlModule        *mod;

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return NULL;
  mod = gowl_module_manager_find_module (mgr, "dropdown");
  if (mod == NULL
      || !GOWL_IS_DROPDOWN_PROVIDER (mod)
      || !gowl_module_get_is_active (mod))
    return NULL;
  return GOWL_DROPDOWN_PROVIDER (mod);
}

DEFUN ("gowl-dropdown-refresh", Fgowl_dropdown_refresh,
       Sgowl_dropdown_refresh, 0, 0, 0,
       doc: /* Refresh the dropdown module from the current gowl config.
Scans the config's dropdown list for any entries not already
registered in the dropdown module and adopts them.  Returns the
number of newly adopted entries, or nil if no dropdown provider
module is loaded. */)
  (void)
{
  GowlDropdownProvider *prov;
  guint                 adopted;

  GOWL_CHECK_RUNNING ();
  prov = cmacs_gowl_find_dropdown_provider ();
  if (prov == NULL)
    return Qnil;
  adopted = gowl_dropdown_provider_refresh (prov);
  return make_fixnum ((EMACS_INT)adopted);
}

DEFUN ("gowl-dropdown-toggle", Fgowl_dropdown_toggle,
       Sgowl_dropdown_toggle, 0, 1, 0,
       doc: /* Toggle the dropdown named NAME.
Finds the first active module implementing `GowlDropdownProvider'
and dispatches the toggle through its interface vfunc.  Returns t
if a matching entry was toggled, nil if the provider or entry is
missing.  Entries added via `gowl-add-dropdown' after module
startup are picked up via the module's config-scan fallback
inside its toggle_by_name implementation.

When NAME is nil or omitted, toggles the first dropdown entry in
the running gowl config — matches `cmacs-gowl-test-dropdown' and
lets callers type `(gowl-dropdown-toggle)' for the common case. */)
  (Lisp_Object name)
{
  GowlDropdownProvider *prov;
  GowlConfig           *config;
  const gchar          *target = NULL;
  gchar                *first_name = NULL;

  GOWL_CHECK_RUNNING ();
  prov = cmacs_gowl_find_dropdown_provider ();
  if (prov == NULL)
    {
      message ("dropdown module not loaded");
      return Qnil;
    }
  if (STRINGP (name))
    {
      target = SSDATA (name);
    }
  else
    {
      GPtrArray *arr;
      config = gowl_compositor_get_config (cmacs_gowl_compositor);
      if (config == NULL)
        return Qnil;
      arr = gowl_config_get_dropdowns (config);
      if (arr == NULL || arr->len == 0)
        {
          message ("no dropdowns registered in gowl config");
          return Qnil;
        }
      {
        GowlDropdownEntry *e = g_ptr_array_index (arr, 0);
        if (e == NULL || e->name == NULL)
          return Qnil;
        first_name = g_strdup (e->name);
        target = first_name;
      }
    }
  {
    gboolean toggled = gowl_dropdown_provider_toggle_by_name (prov, target);
    g_free (first_name);
    return toggled ? Qt : Qnil;
  }
}

DEFUN ("gowl-list-dropdowns", Fgowl_list_dropdowns, Sgowl_list_dropdowns,
       0, 0, 0,
       doc: /* Return a list of dropdown alists. */)
  (void)
{
  GowlConfig *config;
  GPtrArray *arr;
  Lisp_Object result = Qnil;
  guint i;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;
  arr = gowl_config_get_dropdowns (config);
  for (i = 0; i < arr->len; i++)
    {
      GowlDropdownEntry *e = g_ptr_array_index (arr, i);
      Lisp_Object entry;
      Lisp_Object anchor_sym;

      switch (e->anchor) {
      case 1: anchor_sym = intern_c_string ("bottom"); break;
      case 2: anchor_sym = intern_c_string ("left"); break;
      case 3: anchor_sym = intern_c_string ("right"); break;
      default: anchor_sym = intern_c_string ("top"); break;
      }

      entry = Fcons (Fcons (intern_c_string ("name"),
                             build_string (e->name)),
               Fcons (Fcons (intern_c_string ("spawn-cmd"),
                             build_string (e->spawn_cmd)),
               Fcons (Fcons (intern_c_string ("keybind"),
                             e->keybind ? build_string (e->keybind) : Qnil),
               Fcons (Fcons (intern_c_string ("width-pct"),
                             make_float (e->width_pct)),
               Fcons (Fcons (intern_c_string ("height-pct"),
                             make_float (e->height_pct)),
               Fcons (Fcons (intern_c_string ("width"),
                             make_fixnum (e->width_abs)),
               Fcons (Fcons (intern_c_string ("height"),
                             make_fixnum (e->height_abs)),
               Fcons (Fcons (intern_c_string ("anchor"), anchor_sym),
                             Qnil))))))));
      result = Fcons (entry, result);
    }
  return Fnreverse (result);
}


/* ══════════════════════════════════════════════════════════════════════
 * SESSION MANAGEMENT
 * ══════════════════════════════════════════════════════════════════════ */

/* Resolve a PAM service that actually exists in /etc/pam.d so the
   screenlock can authenticate the unlock.  Prefer the cmacs-installed
   "gowl" profile, then the common system stacks.  Returns a static
   string, or NULL when none is present -- in which case we must refuse
   to lock rather than trap the user on an unopenable screen. */
static const char *
cmacs_gowl_resolve_pam_service (void)
{
  static const char *const candidates[] =
    { "gowl", "system-auth", "login", NULL };
  int i;

  for (i = 0; candidates[i] != NULL; i++)
    {
      g_autofree gchar *path =
        g_strconcat ("/etc/pam.d/", candidates[i], NULL);
      if (g_file_test (path, G_FILE_TEST_EXISTS))
        return candidates[i];
    }
  return NULL;
}

/* Ensure the `screenlock' lock-handler module is loaded and active.
   Returns the module, or signals `gowl-error' -- so callers never
   engage a lock with no handler to draw the prompt / take the password.
   Startup is dispatched only on the first load. */
static GowlModule *
cmacs_gowl_ensure_screenlock (GowlModuleManager *mgr)
{
  GowlModule *mod;

  mod = gowl_module_manager_find_module (mgr, "screenlock");
  if (mod != NULL)
    {
      if (!gowl_module_get_is_active (mod))
        gowl_module_activate (mod);
      return mod;
    }

  {
    g_autofree gchar *so_path = cmacs_gowl_find_module ("screenlock");
    g_autoptr (GError) err = NULL;

    if (so_path == NULL)
      xsignal1 (Qgowl_error,
                build_string ("Cannot lock: screenlock module not found"));
    if (!gowl_module_manager_load_module (mgr, so_path, &err))
      xsignal1 (Qgowl_error, build_string (err->message));
  }

  mod = gowl_module_manager_find_module (mgr, "screenlock");
  if (mod == NULL || !GOWL_IS_LOCK_HANDLER (mod))
    xsignal1 (Qgowl_error,
              build_string ("Cannot lock: no lock handler available"));

  gowl_module_activate (mod);
  if (GOWL_IS_STARTUP_HANDLER (mod))
    gowl_startup_handler_on_startup (GOWL_STARTUP_HANDLER (mod),
                                     cmacs_gowl_compositor);
  return mod;
}

DEFUN ("gowl-lock", Fgowl_lock, Sgowl_lock, 0, 0, 0,
       doc: /* Lock the session, showing the screenlock password prompt.

Loads and activates the `screenlock' module if needed, points it at a
working PAM service, then engages the lock through the lock handler so a
password prompt is drawn.  Unlock with your account password (or
`M-x gowl-unlock' as an administrative override).

Rather than leaving you on a blank, unopenable screen, this signals
`gowl-error' when no lock handler can be activated or no PAM service is
found in /etc/pam.d.  In the latter case install the profile with
`sudo make install-cmacs-pam' (or `sudo make install').  */)
  (void)
{
  GowlModuleManager *mgr;
  const char *pam_service;
  GHashTable *inner, *outer;

  GOWL_CHECK_RUNNING ();

  if (gowl_compositor_is_locked (cmacs_gowl_compositor))
    return Qt;

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  /* A working PAM service is required, or the lock could never open. */
  pam_service = cmacs_gowl_resolve_pam_service ();
  if (pam_service == NULL)
    xsignal1 (Qgowl_error,
              build_string ("Refusing to lock: no PAM service in /etc/pam.d"
                            " (install one: `sudo make install-cmacs-pam')"));

  cmacs_gowl_ensure_screenlock (mgr);

  /* Point the screenlock at the resolved service, then engage the lock
     via the handler (draws the password UI; key input is routed to it
     by the compositor's locked-key path). */
  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "pam-service",
                       (gpointer) pam_service);
  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "screenlock", inner);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  gowl_module_manager_dispatch_lock (mgr, (gpointer) cmacs_gowl_compositor);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  g_hash_table_unref (outer);
  g_hash_table_unref (inner);

  /* Never report success on a half-locked state. */
  if (!gowl_compositor_is_locked (cmacs_gowl_compositor))
    xsignal1 (Qgowl_error,
              build_string ("Lock handler failed to engage the session"));

  return Qt;
}

DEFUN ("gowl-unlock", Fgowl_unlock, Sgowl_unlock, 0, 0, 0,
       doc: /* Unlock the session (administrative override; no password).

Tears down the screenlock surfaces via the lock handler when one is
active, then clears the compositor lock state.  Useful as an escape
hatch while testing.  */)
  (void)
{
  GowlModuleManager *mgr;
  GowlModule *mod;

  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  mod = (mgr != NULL)
        ? gowl_module_manager_find_module (mgr, "screenlock") : NULL;

  if (mod != NULL && GOWL_IS_LOCK_HANDLER (mod)
      && gowl_module_get_is_active (mod))
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      gowl_module_manager_dispatch_unlock (mgr,
                                           (gpointer) cmacs_gowl_compositor);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }

  /* Belt and suspenders: ensure the compositor lock state is cleared. */
  gowl_compositor_set_locked (cmacs_gowl_compositor, FALSE);
  return Qt;
}

DEFUN ("gowl-locked-p", Fgowl_locked_p, Sgowl_locked_p, 0, 0, 0,
       doc: /* Return non-nil if the session is locked. */)
  (void)
{
  if (cmacs_gowl_compositor == NULL)
    return Qnil;
  return gowl_compositor_is_locked (cmacs_gowl_compositor) ? Qt : Qnil;
}

DEFUN ("gowl-reload-config", Fgowl_reload_config, Sgowl_reload_config,
       0, 1, 0,
       doc: /* Reload gowl config from PATH, a YAML file.
If PATH is nil, reset the config to built-in defaults without
loading any file.  This never searches the user's config directory;
all configuration when embedded is explicit. */)
  (Lisp_Object path)
{
  GowlConfig *config;

  GOWL_CHECK_RUNNING ();

  if (NILP (path))
    {
      /* Reset to fresh defaults. */
      config = gowl_config_new ();
      gowl_compositor_set_config (cmacs_gowl_compositor, config);
    }
  else
    {
      g_autoptr (GError) err = NULL;
      CHECK_STRING (path);
      config = gowl_compositor_get_config (cmacs_gowl_compositor);
      if (config == NULL)
        error ("No gowl config");
      if (!gowl_config_load_yaml (config, SSDATA (path), &err))
        xsignal1 (Qgowl_error, build_string (err->message));
    }

  return Qt;
}


/* ── Input recording ─────────────────────────────────────────────────
 *
 * The elisp face of GowlInputRecorder.  Present here, and not only over
 * MCP, for one reason above the others: somebody who did not start a
 * recording needs a way to end it.  `gowl-stop-recording' with no
 * argument does that without the token, which is the same guarantee
 * Super+Shift+Escape gives from the keyboard.
 *
 * Consent lives in gowl's own `input-recording' config key and is off
 * by default.  It is deliberately not the switch that allows
 * `send_keys' or any other injection path: capturing what somebody
 * types is a different permission from typing for them.  See
 * deps/gowl/docs/input-recording.org for what the compositor can and
 * cannot recognise as a secret -- in short, the lock screen and an
 * app-id/title deny list, and *not* a password field inside an
 * ordinary window.
 */

/* The compositor's recorder, or signal if gowl is not running.  A
 * missing recorder and a recorder that refuses must not read the
 * same. */
static GowlInputRecorder *
cmacs_gowl_recorder (void)
{
  GowlInputRecorder *rec;

  GOWL_CHECK_RUNNING ();

  rec = gowl_compositor_get_input_recorder (cmacs_gowl_compositor);
  if (rec == NULL)
    error ("Gowl has no input recorder");

  return rec;
}

DEFUN ("gowl-start-recording", Fgowl_start_recording,
       Sgowl_start_recording, 0, 2, 0,
       doc: /* Start recording real key and pointer input.
Return a JSON string carrying the recording's token, its limits and its
counters.  MAX-SECONDS defaults to 120 (maximum 3600) and MAX-EVENTS to
4096 (maximum 100000); the ring drops its oldest entries when full and
reports how many.

Signals `gowl-error' unless gowl's `input-recording' config key is
set -- that key is the consent gate, it is off by default, and it is
separate from anything allowing input injection.

While the recording runs the screen is framed in red.  It stops itself
after MAX-SECONDS, and `gowl-stop-recording' with no argument, or
Super+Shift+Escape, stops it at any time. */)
  (Lisp_Object max_seconds, Lisp_Object max_events)
{
  GowlInputRecorder *rec;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *token = NULL;
  g_autofree gchar *status = NULL;
  guint secs, events;

  rec = cmacs_gowl_recorder ();

  secs = 0;
  events = 0;
  if (!NILP (max_seconds))
    {
      CHECK_FIXNUM (max_seconds);
      if (XFIXNUM (max_seconds) > 0)
        secs = (guint) XFIXNUM (max_seconds);
    }
  if (!NILP (max_events))
    {
      CHECK_FIXNUM (max_events);
      if (XFIXNUM (max_events) > 0)
        events = (guint) XFIXNUM (max_events);
    }

  token = gowl_input_recorder_start (rec, secs, events, &err);
  if (token == NULL)
    xsignal1 (Qgowl_error, build_string (err->message));

  status = gowl_input_recorder_status (rec);
  return build_string (status ? : "{}");
}

DEFUN ("gowl-drain-recording", Fgowl_drain_recording,
       Sgowl_drain_recording, 1, 1, 0,
       doc: /* Take everything recorded since the last drain, as JSON.
TOKEN is the token `gowl-start-recording' returned.  The recording keeps
running.  The reply carries `dropped' (since the last drain) and
`dropped_total', so a demonstration that overflowed the ring is reported
rather than passed off as complete, plus `active' and `stop_reason'. */)
  (Lisp_Object token)
{
  GowlInputRecorder *rec;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *json = NULL;

  CHECK_STRING (token);
  rec = cmacs_gowl_recorder ();

  json = gowl_input_recorder_drain (rec, SSDATA (token), &err);
  if (json == NULL)
    xsignal1 (Qgowl_error, build_string (err->message));

  return build_string (json);
}

DEFUN ("gowl-stop-recording", Fgowl_stop_recording,
       Sgowl_stop_recording, 0, 1, "",
       doc: /* Stop the running input recording.
With TOKEN, stop that recording and return its remaining events as
JSON, the same shape `gowl-drain-recording' returns.

With no TOKEN, stop whatever is running and return t -- this is the way
out for somebody who did not start the recording and has no handle on
it.  Buffered events are kept, so whoever did start it can still drain
them; the stop ends the capture, not the read. */)
  (Lisp_Object token)
{
  GowlInputRecorder *rec;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *json = NULL;

  rec = cmacs_gowl_recorder ();

  if (NILP (token))
    {
      gowl_input_recorder_force_stop (rec, "stopped from cmacs");
      return Qt;
    }

  CHECK_STRING (token);
  json = gowl_input_recorder_stop (rec, SSDATA (token), &err);
  if (json == NULL)
    xsignal1 (Qgowl_error, build_string (err->message));

  return build_string (json);
}

DEFUN ("gowl-recording-status", Fgowl_recording_status,
       Sgowl_recording_status, 0, 0, 0,
       doc: /* Return the input recorder's state as a JSON string.
Consumes nothing.  Carries whether a recording is active, its token,
its limits, how many events were dropped or withheld and why, and a
standing note about what the compositor's secret suppression can and
cannot see. */)
  (void)
{
  GowlInputRecorder *rec;
  g_autofree gchar *json = NULL;

  rec = cmacs_gowl_recorder ();
  json = gowl_input_recorder_status (rec);

  return build_string (json ? : "{}");
}

DEFUN ("gowl-recording-active-p", Fgowl_recording_active_p,
       Sgowl_recording_active_p, 0, 0, 0,
       doc: /* Return t if an input recording is running, else nil. */)
  (void)
{
  GowlInputRecorder *rec;

  rec = cmacs_gowl_recorder ();
  return gowl_input_recorder_is_active (rec) ? Qt : Qnil;
}

DEFUN ("gowl-config-get", Fgowl_config_get, Sgowl_config_get, 1, 1, 0,
       doc: /* Get a config property by name.
Supported: border-width, terminal, menu, mfact, nmaster, tag-count,
           repeat-rate, repeat-delay, sloppyfocus, log-level. */)
  (Lisp_Object property)
{
  GowlConfig *config;
  const gchar *prop;

  CHECK_STRING (property);
  GOWL_CHECK_RUNNING ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;

  prop = SSDATA (property);

  if (g_strcmp0 (prop, "border-width") == 0)
    return make_fixnum (gowl_config_get_border_width (config));
  if (g_strcmp0 (prop, "terminal") == 0)
    return build_string (gowl_config_get_terminal (config) ? : "");
  if (g_strcmp0 (prop, "menu") == 0)
    return build_string (gowl_config_get_menu (config) ? : "");
  if (g_strcmp0 (prop, "mfact") == 0)
    return make_float (gowl_config_get_mfact (config));
  if (g_strcmp0 (prop, "nmaster") == 0)
    return make_fixnum (gowl_config_get_nmaster (config));
  if (g_strcmp0 (prop, "tag-count") == 0)
    return make_fixnum (gowl_config_get_tag_count (config));
  if (g_strcmp0 (prop, "repeat-rate") == 0)
    return make_fixnum (gowl_config_get_repeat_rate (config));
  if (g_strcmp0 (prop, "repeat-delay") == 0)
    return make_fixnum (gowl_config_get_repeat_delay (config));
  if (g_strcmp0 (prop, "sloppyfocus") == 0)
    return gowl_config_get_sloppyfocus (config) ? Qt : Qnil;
  if (g_strcmp0 (prop, "log-level") == 0)
    return build_string (gowl_config_get_log_level (config) ? : "");
  if (g_strcmp0 (prop, "border-color-focus") == 0)
    return build_string (
      gowl_config_get_border_color_focus (config) ? : "");
  if (g_strcmp0 (prop, "border-color-unfocus") == 0)
    return build_string (
      gowl_config_get_border_color_unfocus (config) ? : "");
  if (g_strcmp0 (prop, "border-color-urgent") == 0)
    return build_string (
      gowl_config_get_border_color_urgent (config) ? : "");
  if (g_strcmp0 (prop, "evaluate-gowl-config-with-cmacs") == 0)
    return gowl_config_get_evaluate_gowl_config_with_cmacs (config)
      ? Qt : Qnil;
  if (g_strcmp0 (prop, "evaluate-c-config-with-cmacs") == 0)
    return gowl_config_get_evaluate_c_config_with_cmacs (config)
      ? Qt : Qnil;

  error ("Unknown config property: %s", prop);
}

DEFUN ("gowl-config-generate-yaml", Fgowl_config_generate_yaml,
       Sgowl_config_generate_yaml, 0, 0, 0,
       doc: /* Generate YAML from the current runtime config.
Returns the YAML as a string.  Useful for saving config changes. */)
  (void)
{
  GowlConfig *config;
  gchar *yaml;
  Lisp_Object result;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return Qnil;

  yaml = gowl_config_generate_yaml (config);
  result = build_string (yaml ? yaml : "");
  g_free (yaml);
  return result;
}


/* ══════════════════════════════════════════════════════════════════════
 * MODULE SYSTEM
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-load-module", Fgowl_load_module, Sgowl_load_module,
       1, 1, 0,
       doc: /* Load a gowl module.
PATH is either an absolute path to a .so file, or a bare module
name (e.g. "recording") — in which case the standard search paths
are used to locate the .so, same as `gowl-enable-module'. */)
  (Lisp_Object path)
{
  GowlModuleManager *mgr;
  GError *err = NULL;
  g_autofree gchar *resolved = NULL;
  const gchar *input;

  CHECK_STRING (path);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  input = SSDATA (path);

  /* If the argument is a bare name (no slash and no .so suffix),
     resolve via the standard search paths. */
  if (strchr (input, '/') == NULL && !g_str_has_suffix (input, ".so"))
    {
      resolved = cmacs_gowl_find_module (input);
      if (resolved == NULL)
        xsignal1 (Qgowl_error,
                  concat3 (build_string ("Module not found: "),
                           path, empty_unibyte_string));
      input = resolved;
    }

  if (!gowl_module_manager_load_module (mgr, input, &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgowl_error, msg);
    }

  return Qt;
}

DEFUN ("gowl-list-modules", Fgowl_list_modules, Sgowl_list_modules,
       0, 0, 0,
       doc: /* Return a list of module info alists.
Each element is ((name . NAME) (description . DESC) (version . VER)). */)
  (void)
{
  GowlModuleManager *mgr;
  GList *modules, *l;
  Lisp_Object result = Qnil;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;

  modules = gowl_module_manager_get_modules (mgr);
  for (l = modules; l != NULL; l = l->next)
    {
      GowlModuleInfo *info = (GowlModuleInfo *) l->data;
      const gchar *n = gowl_module_info_get_name (info);
      const gchar *d = gowl_module_info_get_description (info);
      const gchar *v = gowl_module_info_get_version (info);
      Lisp_Object entry = list3 (
        Fcons (intern ("name"), build_string (n ? n : "")),
        Fcons (intern ("description"), build_string (d ? d : "")),
        Fcons (intern ("version"), build_string (v ? v : "")));
      result = Fcons (entry, result);
    }
  g_list_free_full (modules, (GDestroyNotify) gowl_module_info_free);

  return Fnreverse (result);
}

DEFUN ("gowl-load-modules-from-dir", Fgowl_load_modules_from_dir,
       Sgowl_load_modules_from_dir, 1, 1, 0,
       doc: /* Load all gowl modules (.so files) from DIRECTORY. */)
  (Lisp_Object dir)
{
  GowlModuleManager *mgr;

  CHECK_STRING (dir);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  gowl_module_manager_load_from_directory (mgr, SSDATA (dir));
  return Qt;
}

/* Helper: find a loaded module by name. */
static GowlModule *
cmacs_gowl_find_loaded_module (const gchar *name)
{
  GowlModuleManager *mgr;

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return NULL;

  return gowl_module_manager_find_module (mgr, name);
}

DEFUN ("gowl-enable-module", Fgowl_enable_module, Sgowl_enable_module,
       1, 1, 0,
       doc: /* Enable a gowl module by NAME (a string).
Finds the module .so, loads it, activates it, and dispatches startup.
Returns t on success.  Signals `gowl-error' if the module cannot be
found or fails to load. */)
  (Lisp_Object name)
{
  GowlModuleManager *mgr;
  GowlModule *mod;
  g_autofree gchar *so_path = NULL;
  g_autoptr (GError) err = NULL;

  CHECK_STRING (name);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  /* Already loaded? */
  mod = cmacs_gowl_find_loaded_module (SSDATA (name));
  if (mod != NULL)
    {
      if (!gowl_module_get_is_active (mod))
        gowl_module_activate (mod);
      return Qt;
    }

  /* Find the .so */
  so_path = cmacs_gowl_find_module (SSDATA (name));
  if (so_path == NULL)
    xsignal1 (Qgowl_error,
              concat3 (build_string ("Module not found: "),
                       name, empty_unibyte_string));

  if (!gowl_module_manager_load_module (mgr, so_path, &err))
    xsignal1 (Qgowl_error, build_string (err->message));

  /* Look up the module by name — safer than assuming list position. */
  mod = cmacs_gowl_find_loaded_module (SSDATA (name));
  if (mod == NULL)
    xsignal1 (Qgowl_error,
              concat3 (build_string ("Module loaded but not found: "),
                       name, empty_unibyte_string));

  gowl_module_activate (mod);

  /* Dispatch startup if the module implements the interface. */
  if (GOWL_IS_STARTUP_HANDLER (mod))
    gowl_startup_handler_on_startup (GOWL_STARTUP_HANDLER (mod),
                                     cmacs_gowl_compositor);

  return Qt;
}

DEFUN ("gowl-disable-module", Fgowl_disable_module, Sgowl_disable_module,
       1, 1, 0,
       doc: /* Disable a loaded gowl module by NAME.
Deactivates the module.  Returns t if found, nil otherwise. */)
  (Lisp_Object name)
{
  GowlModule *mod;

  CHECK_STRING (name);
  GOWL_CHECK_RUNNING ();

  mod = cmacs_gowl_find_loaded_module (SSDATA (name));
  if (mod == NULL)
    return Qnil;

  if (gowl_module_get_is_active (mod))
    gowl_module_deactivate (mod);
  return Qt;
}

DEFUN ("gowl-configure-module", Fgowl_configure_module,
       Sgowl_configure_module, 2, 2, 0,
       doc: /* Configure module NAME with ALIST.
ALIST is an association list of (KEY . VALUE) pairs where both KEY
and VALUE are strings.  Builds the module config hash and calls
gowl_module_manager_configure_all. */)
  (Lisp_Object name, Lisp_Object alist)
{
  GowlModuleManager *mgr;
  GHashTable *inner, *outer;
  Lisp_Object tail, pair;

  CHECK_STRING (name);
  CHECK_LIST (alist);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  /* Convert alist to GHashTable<str,str>. */
  inner = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      pair = XCAR (tail);
      if (!CONSP (pair))
        continue;
      CHECK_STRING (XCAR (pair));
      CHECK_STRING (XCDR (pair));
      g_hash_table_insert (inner,
                           g_strdup (SSDATA (XCAR (pair))),
                           g_strdup (SSDATA (XCDR (pair))));
    }

  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, SSDATA (name), inner);

  /* Lock the compositor mutex — configure may trigger scene graph
     modifications (e.g. bar_redraw_all calls wlr_scene_buffer_set_buffer). */
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  g_hash_table_unref (outer);
  g_hash_table_unref (inner);
  return Qt;
}


/* ══════════════════════════════════════════════════════════════════════
 * WALLPAPER
 * ══════════════════════════════════════════════════════════════════════ */

/* Track the last-set wallpaper path and mode so gowl-wallpaper-info can
   return them without poking into the module's private struct. */
static gchar *cmacs_wallpaper_path;
static gchar *cmacs_wallpaper_mode;

DEFUN ("gowl-set-wallpaper", Fgowl_set_wallpaper, Sgowl_set_wallpaper,
       1, 2, 0,
       doc: /* Set the desktop wallpaper to IMAGE-PATH.
Optional MODE is a scaling mode string: "fill" (default), "fit",
"center", "stretch", or "tile".
Configures the wallpaper module and applies to all current monitors. */)
  (Lisp_Object image_path, Lisp_Object mode)
{
  GowlModuleManager *mgr;
  GHashTable *outer, *inner;
  GList *monitors, *l;
  const gchar *mode_str;

  CHECK_STRING (image_path);
  if (!NILP (mode))
    CHECK_STRING (mode);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  mode_str = NILP (mode) ? "fill" : SSDATA (mode);

  /* Build the module_configs hash:
     { "wallpaper" => { "path" => PATH, "mode" => MODE } } */
  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "path", SSDATA (image_path));
  g_hash_table_insert (inner, (gpointer) "mode", (gpointer) mode_str);

  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "wallpaper", inner);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  /* Re-dispatch wallpaper on every monitor to apply immediately. */
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    gowl_module_manager_dispatch_wallpaper_output (mgr,
                                                   cmacs_gowl_compositor,
                                                   l->data);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  g_hash_table_unref (outer);
  g_hash_table_unref (inner);

  /* Track for gowl-wallpaper-info. */
  g_free (cmacs_wallpaper_path);
  cmacs_wallpaper_path = g_strdup (SSDATA (image_path));
  g_free (cmacs_wallpaper_mode);
  cmacs_wallpaper_mode = g_strdup (mode_str);

  return Qt;
}

DEFUN ("gowl-wallpaper-info", Fgowl_wallpaper_info, Sgowl_wallpaper_info,
       0, 0, 0,
       doc: /* Return the current wallpaper configuration as an alist.
Keys: path (image file), mode (scaling mode).
Returns nil if no wallpaper has been set. */)
  (void)
{
  if (cmacs_wallpaper_path == NULL)
    return Qnil;

  return list2 (Fcons (intern ("path"),
                       build_string (cmacs_wallpaper_path)),
                Fcons (intern ("mode"),
                       build_string (cmacs_wallpaper_mode
                                     ? cmacs_wallpaper_mode : "fill")));
}


/* ══════════════════════════════════════════════════════════════════════
 * ALPHA / OPACITY
 * ══════════════════════════════════════════════════════════════════════ */

static gfloat cmacs_alpha_focused = 1.0f;
static gfloat cmacs_alpha_unfocused = 0.8f;

DEFUN ("gowl-set-client-alpha", Fgowl_set_client_alpha,
       Sgowl_set_client_alpha, 2, 2, 0,
       doc: /* Set the opacity of CLIENT to ALPHA (a float 0.0 to 1.0).
Immediately walks the client's scene tree and applies the opacity. */)
  (Lisp_Object client, Lisp_Object alpha)
{
  GowlClient *c;
  double val;

  GOWL_CHECK_RUNNING ();
  c = gowl_resolve_client (client);
  CHECK_NUMBER (alpha);
  val = XFLOATINT (alpha);
  gowl_client_set_alpha (c, (gfloat) val);
  return Qt;
}

DEFUN ("gowl-set-all-alpha", Fgowl_set_all_alpha,
       Sgowl_set_all_alpha, 1, 1, 0,
       doc: /* Set opacity of ALL clients to ALPHA (a float 0.0 to 1.0).
Returns the number of clients affected. */)
  (Lisp_Object alpha)
{
  GList *clients, *l;
  double val;
  int count = 0;

  CHECK_NUMBER (alpha);
  GOWL_CHECK_RUNNING ();
  val = XFLOATINT (alpha);

  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = GOWL_CLIENT (l->data);
      gowl_client_set_alpha (c, (gfloat) val);
      count++;
    }

  message1 (SSDATA (CALLN (Fformat,
    build_string ("gowl: set alpha %.2f on %d clients"),
    alpha, make_fixnum (count))));

  return make_fixnum (count);
}

DEFUN ("gowl-set-focused-alpha", Fgowl_set_focused_alpha,
       Sgowl_set_focused_alpha, 1, 1, 0,
       doc: /* Set the alpha module's focused window opacity to ALPHA.
Configures the alpha module and re-applies immediately. */)
  (Lisp_Object alpha)
{
  GowlModuleManager *mgr;
  GHashTable *inner, *outer;
  /* 320, not 64: "%.4f" of an unconstrained double wants up to 315
     bytes, and GCC will not narrow that through the CLAMP below (float
     range propagation gives up on the NaN case), so the buffer is sized
     for the format instead of the value.  The clamp still matters --
     it is what makes the value meaningful to the compositor. */
  char buf[320];
  gfloat a;

  CHECK_NUMBER (alpha);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  /* Validated and clamped before it is formatted, and that is the fix
     rather than a bigger buffer: an alpha that is not a finite number in
     0..1 is meaningless to the compositor.  It also bounds the
     formatting -- "%.4f" of an unconstrained float wants up to 315
     bytes, which is what -Wformat-truncation was pointing at. */
  a = (gfloat) XFLOATINT (alpha);
  if (!isfinite (a))
    error ("Alpha must be a finite number");
  a = CLAMP (a, 0.0f, 1.0f);
  cmacs_alpha_focused = a;
  snprintf (buf, sizeof buf, "%.4f", (gdouble) a);

  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "focused-alpha", buf);
  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "alpha", inner);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  g_hash_table_unref (outer);
  g_hash_table_unref (inner);
  return Qt;
}

DEFUN ("gowl-set-unfocused-alpha", Fgowl_set_unfocused_alpha,
       Sgowl_set_unfocused_alpha, 1, 1, 0,
       doc: /* Set the alpha module's unfocused window opacity to ALPHA.
Configures the alpha module and re-applies immediately. */)
  (Lisp_Object alpha)
{
  GowlModuleManager *mgr;
  GHashTable *inner, *outer;
  /* 320, not 64: "%.4f" of an unconstrained double wants up to 315
     bytes, and GCC will not narrow that through the CLAMP below (float
     range propagation gives up on the NaN case), so the buffer is sized
     for the format instead of the value.  The clamp still matters --
     it is what makes the value meaningful to the compositor. */
  char buf[320];
  gfloat a;

  CHECK_NUMBER (alpha);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  /* Validated and clamped before it is formatted, and that is the fix
     rather than a bigger buffer: an alpha that is not a finite number in
     0..1 is meaningless to the compositor.  It also bounds the
     formatting -- "%.4f" of an unconstrained float wants up to 315
     bytes, which is what -Wformat-truncation was pointing at. */
  a = (gfloat) XFLOATINT (alpha);
  if (!isfinite (a))
    error ("Alpha must be a finite number");
  a = CLAMP (a, 0.0f, 1.0f);
  cmacs_alpha_unfocused = a;
  snprintf (buf, sizeof buf, "%.4f", (gdouble) a);

  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "unfocused-alpha", buf);
  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "alpha", inner);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  g_hash_table_unref (outer);
  g_hash_table_unref (inner);
  return Qt;
}

DEFUN ("gowl-alpha-info", Fgowl_alpha_info, Sgowl_alpha_info,
       0, 0, 0,
       doc: /* Return the current alpha module configuration as an alist.
Returns ((focused-alpha . F) (unfocused-alpha . F)) or nil if
the alpha module has never been configured. */)
  (void)
{
  GowlModule *mod;

  GOWL_CHECK_RUNNING ();

  mod = cmacs_gowl_find_loaded_module ("alpha");
  if (mod == NULL)
    return Qnil;

  return list2 (Fcons (intern ("focused-alpha"),
                       make_float (cmacs_alpha_focused)),
                Fcons (intern ("unfocused-alpha"),
                       make_float (cmacs_alpha_unfocused)));
}

/* ══════════════════════════════════════════════════════════════════════
 * GAPS (vanitygaps)
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-set-gaps", Fgowl_set_gaps, Sgowl_set_gaps, 1, 1, 0,
       doc: /* Configure the vanitygaps module with ALIST.
ALIST is an alist of string key-value pairs.  Supported keys:
"inner-gap", "outer-gap", "inner-h", "inner-v", "outer-h", "outer-v".
Re-arranges all monitors immediately. */)
  (Lisp_Object alist)
{
  GowlModuleManager *mgr;
  GHashTable *inner, *outer;
  GList *monitors, *l;
  Lisp_Object tail, pair;

  CHECK_LIST (alist);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  inner = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      pair = XCAR (tail);
      if (!CONSP (pair))
        continue;
      CHECK_STRING (XCAR (pair));
      CHECK_STRING (XCDR (pair));
      g_hash_table_insert (inner,
                           g_strdup (SSDATA (XCAR (pair))),
                           g_strdup (SSDATA (XCDR (pair))));
    }

  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "vanitygaps", inner);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  /* Re-arrange all monitors so gaps take effect immediately. */
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    gowl_compositor_arrange (cmacs_gowl_compositor, l->data);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  g_hash_table_unref (outer);
  g_hash_table_unref (inner);

  return Qt;
}

DEFUN ("gowl-gaps-info", Fgowl_gaps_info, Sgowl_gaps_info, 0, 0, 0,
       doc: /* Return the current gap configuration as an alist.
Returns ((inner-h . N) (inner-v . N) (outer-h . N) (outer-v . N))
or nil if no gap provider is active. */)
  (void)
{
  GowlModuleManager *mgr;
  GowlMonitor *mon;
  gint ih = 0, iv = 0, oh = 0, ov = 0;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;

  mon = gowl_get_focused_monitor ();
  if (!gowl_module_manager_get_gaps (mgr, mon, &ih, &iv, &oh, &ov))
    return Qnil;

  return list4 (Fcons (intern ("inner-h"), make_fixnum (ih)),
                Fcons (intern ("inner-v"), make_fixnum (iv)),
                Fcons (intern ("outer-h"), make_fixnum (oh)),
                Fcons (intern ("outer-v"), make_fixnum (ov)));
}

/* ══════════════════════════════════════════════════════════════════════
 * SCREENLOCK
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-configure-screenlock", Fgowl_configure_screenlock,
       Sgowl_configure_screenlock, 1, 1, 0,
       doc: /* Configure the screenlock module with ALIST.
ALIST is an alist of string key-value pairs.  Supported keys:
"pam-service", "auto-lock-timeout", "bg-color", "text-color",
"indicator-color", "error-color", "font", "font-size". */)
  (Lisp_Object alist)
{
  GowlModuleManager *mgr;
  GHashTable *inner, *outer;
  Lisp_Object tail, pair;

  CHECK_LIST (alist);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  inner = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      pair = XCAR (tail);
      if (!CONSP (pair))
        continue;
      CHECK_STRING (XCAR (pair));
      CHECK_STRING (XCDR (pair));
      g_hash_table_insert (inner,
                           g_strdup (SSDATA (XCAR (pair))),
                           g_strdup (SSDATA (XCDR (pair))));
    }

  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "screenlock", inner);
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  g_hash_table_unref (outer);
  g_hash_table_unref (inner);
  return Qt;
}

/* ══════════════════════════════════════════════════════════════════════
 * SCRATCHPAD
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-scratchpad-toggle", Fgowl_scratchpad_toggle,
       Sgowl_scratchpad_toggle, 1, 1, 0,
       doc: /* Toggle a named scratchpad window.
NAME is a string identifying the scratchpad.
Returns t if the scratchpad module handled the request. */)
  (Lisp_Object name)
{
  GowlModuleManager *mgr;
  GowlModule        *mod;

  CHECK_STRING (name);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  mod = gowl_module_manager_find_module (mgr, "scratchpad");
  if (mod == NULL
      || !GOWL_IS_SCRATCHPAD_HANDLER (mod)
      || !gowl_module_get_is_active (mod))
    return Qnil;

  gowl_scratchpad_handler_toggle_scratchpad (
    GOWL_SCRATCHPAD_HANDLER (mod), SSDATA (name));
  return Qt;
}


DEFUN ("gowl-frame-origin", Fgowl_frame_origin, Sgowl_frame_origin,
       0, 0, 0,
       doc: /* Return the Emacs frame's content origin on the monitor as (X . Y).
Finds the non-embedded tiled client (the Emacs frame) and returns
its geometry position plus border width.  Accounts for bar height
and vanitygaps. */)
  (void)
{
  GList *clients, *l;
  gint x, y, bw;

  GOWL_CHECK_RUNNING ();

  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = GOWL_CLIENT (l->data);
      if (!gowl_client_get_embedded (c))
        {
          gowl_client_get_geometry (c, &x, &y, NULL, NULL);
          bw = (gint) gowl_client_get_border_width (c);
          return Fcons (make_fixnum (x + bw), make_fixnum (y + bw));
        }
    }
  return Fcons (make_fixnum (0), make_fixnum (0));
}

/* ══════════════════════════════════════════════════════════════════════
 * BAR
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-usable-area", Fgowl_usable_area, Sgowl_usable_area,
       0, 0, 0,
       doc: /* Return the focused monitor's usable window area.
Shows (x y width height) after bar and layer-shell subtraction. */)
  (void)
{
  GowlMonitor *mon;
  gint x, y, w, h;

  GOWL_CHECK_RUNNING ();
  mon = gowl_get_focused_monitor ();
  if (mon == NULL)
    return Qnil;

  gowl_monitor_get_window_area (mon, &x, &y, &w, &h);
  return list4 (make_fixnum (x), make_fixnum (y),
                make_fixnum (w), make_fixnum (h));
}

DEFUN ("gowl-bar-enable", Fgowl_bar_enable, Sgowl_bar_enable,
       0, 0, 0,
       doc: /* Enable the compositor status bar.
Loads the bar module, activates it, and recalculates the usable
area on all monitors so tiling accounts for the bar height. */)
  (void)
{
  GList *monitors, *l;

  GOWL_CHECK_RUNNING ();
  Fgowl_enable_module (build_string ("bar"));

  /* Recalculate usable area (subtracts bar height) and re-tile.
     Must hold mutex — arrangelayers modifies the scene graph. */
  pthread_mutex_lock (&cmacs_gowl_mutex);
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    gowl_compositor_arrangelayers (cmacs_gowl_compositor, l->data);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-bar-disable", Fgowl_bar_disable, Sgowl_bar_disable,
       0, 0, 0,
       doc: /* Disable the compositor status bar.
Deactivates the bar module and reclaims the tiling space. */)
  (void)
{
  GList *monitors, *l;

  GOWL_CHECK_RUNNING ();
  Fgowl_disable_module (build_string ("bar"));

  /* Recalculate usable area (bar height now 0) and re-tile.
     Must hold mutex — arrangelayers modifies the scene graph. */
  pthread_mutex_lock (&cmacs_gowl_mutex);
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    gowl_compositor_arrangelayers (cmacs_gowl_compositor, l->data);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-bar-configure", Fgowl_bar_configure,
       Sgowl_bar_configure, 1, 1, 0,
       doc: /* Configure the status bar with ALIST.
Keys: "height", "bg-color", "fg-color", "font", "font-size",
"show-tags" (true/false), and the tag-indicator colours
"tag-active-bg", "tag-active-fg", "tag-occupied-fg",
"tag-urgent-bg", "tag-urgent-fg", "tag-empty-fg".
Re-arranges monitors if height changed. */)
  (Lisp_Object alist)
{
  GList *monitors, *l;

  CHECK_LIST (alist);
  GOWL_CHECK_RUNNING ();

  Fgowl_configure_module (build_string ("bar"), alist);

  /* Recalculate usable area in case height changed.
     Must hold mutex — arrangelayers modifies the scene graph. */
  pthread_mutex_lock (&cmacs_gowl_mutex);
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    gowl_compositor_arrangelayers (cmacs_gowl_compositor, l->data);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  return Qt;
}

DEFUN ("gowl-bar-redraw", Fgowl_bar_redraw, Sgowl_bar_redraw,
       0, 0, 0,
       doc: /* Force a full redraw of all bar surfaces. */)
  (void)
{
  GowlModuleManager *mgr;
  GList *monitors, *l;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;

  pthread_mutex_lock (&cmacs_gowl_mutex);
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    gowl_module_manager_dispatch_bar_render (mgr, cmacs_gowl_compositor,
                                             l->data);
  pthread_mutex_unlock (&cmacs_gowl_mutex);
  return Qt;
}

DEFUN ("gowl-bar-set-title", Fgowl_bar_set_title,
       Sgowl_bar_set_title, 1, 2, 0,
       doc: /* Set the bar's displayed title to TITLE (a string).
Overrides the default focused-client title.  Pass nil to clear
the override and revert to the focused client title.

Optional POSITION selects which bar slot receives the title:
  `top' (default) or `bottom'.

Triggers an immediate redraw. */)
  (Lisp_Object title, Lisp_Object position)
{
  GHashTable *inner, *outer;
  GowlModuleManager *mgr;
  const char *pos_str;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;

  /* Resolve POSITION.  Symbols `top and `bottom are accepted;
     anything else (including nil) defaults to `top. */
  pos_str = "top";
  if (EQ (position, intern ("bottom")))
    pos_str = "bottom";

  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "title",
                       NILP (title) ? (gpointer) "" : SSDATA (title));
  g_hash_table_insert (inner, (gpointer) "position",
                       (gpointer) pos_str);
  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "bar", inner);

  /* Lock the compositor mutex — configure triggers bar_redraw_all
     which modifies the scene graph (wlr_scene_buffer_set_buffer). */
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  g_hash_table_unref (outer);
  g_hash_table_unref (inner);
  return Qt;
}


/* ── Xwidget integration ─────────────────────────────────────────────
 *
 * When HAVE_XWIDGETS is enabled alongside HAVE_CMACS_GOWL, embedded
 * Wayland clients render as xwidget buffer content instead of floating
 * overlays.  The xwidget display engine (XWIDGET_GLYPH) handles
 * positioning and clipping automatically; we just provide the draw
 * and event callbacks.
 */

#ifdef HAVE_XWIDGETS

void
cmacs_gowl_xwidget_setup (struct xwidget *xw, GtkWidget *view_widget,
                          struct frame *frame)
{
  struct gowl_embed_view *view;
  struct wlr_surface *surface;
  GowlClient *c = (GowlClient *) xw->gowl_client;

  if (c == NULL)
    return;

  view = g_new0 (struct gowl_embed_view, 1);
  view->client = c;
  view->widget = view_widget;
  view->emacs_frame = frame;
  view->view_w = xw->width;
  view->view_h = xw->height;
  view->xwidget_managed = TRUE;

  /* Configure the client to render at widget size. */
  gowl_client_set_visible (c, FALSE);
  gowl_client_set_embedded (c, TRUE);
  gowl_client_set_border_width (c, 0);
  gowl_compositor_position_embedded (cmacs_gowl_compositor, c,
                                     0, 0, view->view_w, view->view_h);

  /* Listen for surface commits to capture new frames. */
  surface = gowl_client_get_wlr_surface (c);
  if (surface != NULL)
    {
      view->commit.notify = gowl_embed_view_on_commit;
      wl_signal_add (&surface->events.commit, &view->commit);
      view->destroy.notify = gowl_embed_view_on_surface_destroy;
      wl_signal_add (&surface->events.destroy, &view->destroy);
    }
  else
    {
      wl_list_init (&view->commit.link);
      wl_list_init (&view->destroy.link);
    }

  xw->gowl_view = view;

  if (embed_views == NULL)
    embed_views = g_hash_table_new (g_direct_hash, g_direct_equal);
  g_hash_table_insert (embed_views, c, view);
}

GtkWidget *
cmacs_gowl_xwidget_get_widget (struct xwidget *xw)
{
  struct gowl_embed_view *view = (struct gowl_embed_view *) xw->gowl_view;
  if (view == NULL)
    return NULL;
  return view->widget;
}

void
cmacs_gowl_xwidget_teardown (struct xwidget *xw)
{
  struct gowl_embed_view *view = (struct gowl_embed_view *) xw->gowl_view;
  GowlClient *c = (GowlClient *) xw->gowl_client;

  if (view == NULL)
    return;

  /* The xwidget system destroys the GtkWidget — don't double-free. */
  view->widget = NULL;

  if (embed_views != NULL && c != NULL)
    g_hash_table_remove (embed_views, c);

  gowl_embed_view_free (view);
  xw->gowl_view = NULL;

  /* Close the Wayland client. */
  if (c != NULL && cmacs_gowl_compositor != NULL)
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      gowl_client_close (c);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }
}

gboolean
cmacs_gowl_xwidget_draw_cb (GtkWidget *widget, cairo_t *cr, gpointer data)
{
  /* Look up the current xwidget view from the widget, not from the
     signal user data.  The view may have been recreated after a
     tab/workspace switch while the widget (and its signal handlers)
     survived.  */
  struct xwidget_view *xv
    = g_object_get_data (G_OBJECT (widget), XG_XWIDGET_VIEW);
  struct xwidget *xw;
  struct gowl_embed_view *view;
  (void) data;

  if (xv == NULL)
    return FALSE;

  xw = XXWIDGET (xv->model);
  view = (struct gowl_embed_view *) xw->gowl_view;

  if (view == NULL)
    return FALSE;

  /* Update view dimensions from xwidget (may have been resized). */
  view->view_w = xw->width;
  view->view_h = xw->height;

  return gowl_embed_view_draw (widget, cr, view);
}

gboolean
cmacs_gowl_xwidget_event_cb (GtkWidget *widget, GdkEvent *event,
                              gpointer data)
{
  struct xwidget_view *xv
    = g_object_get_data (G_OBJECT (widget), XG_XWIDGET_VIEW);
  struct xwidget *xw;
  struct gowl_embed_view *view;
  (void) data;

  if (xv == NULL)
    return FALSE;

  xw = XXWIDGET (xv->model);
  view = (struct gowl_embed_view *) xw->gowl_view;

  if (view == NULL)
    return FALSE;

  /* Update focus state for keyboard routing by the edit_widget
     forwarder.  GDK routes pointer events to the DrawingArea
     directly — they never reach the edit_widget — so the DrawingArea
     must manage the focus state here.  */
  switch (event->type)
    {
    case GDK_ENTER_NOTIFY:
      xwidget_gowl_set_focused_view (xv);
      cmacs_gowl_xwidget_keyboard_enter (xw);
      break;
    case GDK_LEAVE_NOTIFY:
      xwidget_gowl_clear_focused_view ();
      cmacs_gowl_xwidget_keyboard_leave ();
      break;
    case GDK_BUTTON_PRESS:
      /* Reinforce on click — enter may have been missed if the widget
         appeared under an already-stationary pointer. */
      xwidget_gowl_set_focused_view (xv);
      break;
    default:
      break;
    }

  return gowl_embed_view_event (widget, event, view);
}

DEFUN ("gowl-make-xwidget", Fgowl_make_xwidget, Sgowl_make_xwidget,
       3, 4, 0,
       doc: /* Create a gowl xwidget for CLIENT with size WIDTH x HEIGHT.
CLIENT is a gowl client object.  Optional BUFFER defaults to current buffer.
Returns an xwidget object suitable for use in display properties. */)
  (Lisp_Object client, Lisp_Object width, Lisp_Object height,
   Lisp_Object buffer)
{
  GowlClient *c;
  struct xwidget *xw;
  Lisp_Object val;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);

  c = gowl_resolve_client (client);

  val = cmacs_xwidget_allocate_gowl (buffer, XFIXNAT (width),
                                      XFIXNAT (height));
  xw = XXWIDGET (val);
  xw->gowl_client = c;

  return val;
}

#endif /* HAVE_XWIDGETS */


/* ══════════════════════════════════════════════════════════════════════
 * GObject sub-object accessors
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-seat", Fgowl_seat, Sgowl_seat, 0, 0, 0,
       doc: /* Return the GowlSeat GObject wrapping the Wayland seat.
Signals: "focus-changed".
Use gobject-connect to listen for focus changes. */)
  (void)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (seat));
}

DEFUN ("gowl-cursor", Fgowl_cursor, Sgowl_cursor, 0, 0, 0,
       doc: /* Return the GowlCursor GObject.
Signals: "motion", "button", "axis".
Properties accessible via gobject-get: "mode". */)
  (void)
{
  GowlCursor *cursor;

  GOWL_CHECK_RUNNING ();
  cursor = gowl_compositor_get_cursor (cmacs_gowl_compositor);
  if (cursor == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (cursor));
}

DEFUN ("gowl-keyboard-group", Fgowl_keyboard_group,
       Sgowl_keyboard_group, 0, 0, 0,
       doc: /* Return the GowlKeyboardGroup GObject.
Signals: "key", "modifiers".
Properties: repeat-rate, repeat-delay. */)
  (void)
{
  GowlKeyboardGroup *kb;

  GOWL_CHECK_RUNNING ();
  kb = gowl_compositor_get_keyboard_group (cmacs_gowl_compositor);
  if (kb == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (kb));
}

DEFUN ("gowl-idle-manager", Fgowl_idle_manager,
       Sgowl_idle_manager, 0, 0, 0,
       doc: /* Return the GowlIdleManager GObject.
Signals: "idle", "resume".
Properties: timeout, state. */)
  (void)
{
  GowlIdleManager *mgr;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_idle_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (mgr));
}

DEFUN ("gowl-bar", Fgowl_bar, Sgowl_bar, 0, 0, 0,
       doc: /* Return the GowlBar GObject, or nil if no bar is active.
Signals: "render", "click".
Properties: height, visible. */)
  (void)
{
  GowlBar *bar;

  GOWL_CHECK_RUNNING ();
  bar = gowl_compositor_get_bar (cmacs_gowl_compositor);
  if (bar == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (bar));
}


/* ══════════════════════════════════════════════════════════════════════
 * Swap / Zoom
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-swap-clients", Fgowl_swap_clients,
       Sgowl_swap_clients, 2, 2, 0,
       doc: /* Swap CLIENT1 and CLIENT2 positions in the tiling list.
Both arguments must be GowlClient GObjects.  The layout is
re-arranged on affected monitors after the swap. */)
  (Lisp_Object client1, Lisp_Object client2)
{
  GOWL_CHECK_RUNNING ();
  gowl_compositor_swap_clients (cmacs_gowl_compositor,
                                gowl_resolve_client (client1),
                                gowl_resolve_client (client2));
  return Qnil;
}

DEFUN ("gowl-zoom-client", Fgowl_zoom_client,
       Sgowl_zoom_client, 0, 1, 0,
       doc: /* Promote CLIENT to master (head of tiling list).
If CLIENT is already master, promote the next visible tiled client.
If CLIENT is nil, operate on the focused client.
Floating clients are ignored. */)
  (Lisp_Object client)
{
  GowlClient *c = NULL;

  GOWL_CHECK_RUNNING ();
  if (!NILP (client))
    c = gowl_resolve_client (client);
  gowl_compositor_zoom_client (cmacs_gowl_compositor, c);
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Cursor / Keyboard accessors
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-cursor-mode", Fgowl_cursor_mode,
       Sgowl_cursor_mode, 0, 0, 0,
       doc: /* Return the current cursor mode as an integer.
0 = normal, 1 = move, 2 = resize. */)
  (void)
{
  GowlCursor *cursor;

  GOWL_CHECK_RUNNING ();
  cursor = gowl_compositor_get_cursor (cmacs_gowl_compositor);
  if (cursor == NULL)
    return Qnil;
  return make_fixnum (gowl_cursor_get_mode (cursor));
}

DEFUN ("gowl-set-cursor-mode", Fgowl_set_cursor_mode,
       Sgowl_set_cursor_mode, 1, 1, 0,
       doc: /* Set the cursor mode to MODE (integer).
0 = normal, 1 = move, 2 = resize. */)
  (Lisp_Object mode)
{
  GowlCursor *cursor;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (mode);
  cursor = gowl_compositor_get_cursor (cmacs_gowl_compositor);
  if (cursor != NULL)
    gowl_cursor_set_mode (cursor, (gint) XFIXNUM (mode));
  return Qnil;
}

DEFUN ("gowl-keyboard-repeat-rate", Fgowl_keyboard_repeat_rate,
       Sgowl_keyboard_repeat_rate, 0, 0, 0,
       doc: /* Return the keyboard repeat rate (keys per second). */)
  (void)
{
  GowlKeyboardGroup *kb;

  GOWL_CHECK_RUNNING ();
  kb = gowl_compositor_get_keyboard_group (cmacs_gowl_compositor);
  if (kb == NULL)
    return Qnil;
  return make_fixnum (gowl_keyboard_group_get_repeat_rate (kb));
}

DEFUN ("gowl-set-keyboard-repeat-rate", Fgowl_set_keyboard_repeat_rate,
       Sgowl_set_keyboard_repeat_rate, 1, 1, 0,
       doc: /* Set the keyboard repeat rate to RATE (keys per second). */)
  (Lisp_Object rate)
{
  GowlKeyboardGroup *kb;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (rate);
  kb = gowl_compositor_get_keyboard_group (cmacs_gowl_compositor);
  if (kb != NULL)
    gowl_keyboard_group_set_repeat_rate (kb, (gint) XFIXNAT (rate));
  return Qnil;
}

DEFUN ("gowl-keyboard-repeat-delay", Fgowl_keyboard_repeat_delay,
       Sgowl_keyboard_repeat_delay, 0, 0, 0,
       doc: /* Return the keyboard repeat delay in milliseconds. */)
  (void)
{
  GowlKeyboardGroup *kb;

  GOWL_CHECK_RUNNING ();
  kb = gowl_compositor_get_keyboard_group (cmacs_gowl_compositor);
  if (kb == NULL)
    return Qnil;
  return make_fixnum (gowl_keyboard_group_get_repeat_delay (kb));
}

DEFUN ("gowl-set-keyboard-repeat-delay", Fgowl_set_keyboard_repeat_delay,
       Sgowl_set_keyboard_repeat_delay, 1, 1, 0,
       doc: /* Set the keyboard repeat delay to DELAY milliseconds. */)
  (Lisp_Object delay)
{
  GowlKeyboardGroup *kb;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (delay);
  kb = gowl_compositor_get_keyboard_group (cmacs_gowl_compositor);
  if (kb != NULL)
    gowl_keyboard_group_set_repeat_delay (kb, (gint) XFIXNAT (delay));
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * IPC
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-ipc-push-event", Fgowl_ipc_push_event,
       Sgowl_ipc_push_event, 1, 1, 0,
       doc: /* Push EVENT-STRING to all connected IPC subscribers.
The string is sent as-is on the IPC event channel. */)
  (Lisp_Object event_string)
{
  GowlIpc *ipc;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (event_string);
  ipc = gowl_compositor_get_ipc (cmacs_gowl_compositor);
  if (ipc != NULL)
    gowl_ipc_push_event (ipc, "%s", SSDATA (event_string));
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Input injection
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-send-key", Fgowl_send_key, Sgowl_send_key, 2, 2, 0,
       doc: /* Send a synthetic key event.
KEYCODE is the XKB keycode.  PRESSED is non-nil for press, nil for release. */)
  (Lisp_Object keycode, Lisp_Object pressed)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (keycode);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_send_key (seat, (guint32) XFIXNAT (keycode), !NILP (pressed));
  return Qnil;
}

DEFUN ("gowl-send-mouse-move", Fgowl_send_mouse_move,
       Sgowl_send_mouse_move, 2, 2, 0,
       doc: /* Move the cursor to absolute coordinates X, Y. */)
  (Lisp_Object x, Lisp_Object y)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_NUMBER (x);
  CHECK_NUMBER (y);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_send_mouse_move (seat, XFLOATINT (x), XFLOATINT (y));
  return Qnil;
}

DEFUN ("gowl-send-mouse-button", Fgowl_send_mouse_button,
       Sgowl_send_mouse_button, 2, 2, 0,
       doc: /* Send a synthetic mouse button event.
BUTTON is the button code.  PRESSED is non-nil for press, nil for release. */)
  (Lisp_Object button, Lisp_Object pressed)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (button);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_send_mouse_button (seat, (guint32) XFIXNAT (button),
                                  !NILP (pressed));
  return Qnil;
}

DEFUN ("gowl-send-scroll", Fgowl_send_scroll,
       Sgowl_send_scroll, 2, 2, 0,
       doc: /* Send a synthetic scroll event with deltas DX, DY. */)
  (Lisp_Object dx, Lisp_Object dy)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_NUMBER (dx);
  CHECK_NUMBER (dy);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_send_scroll (seat, XFLOATINT (dx), XFLOATINT (dy));
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Screenshots
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-screenshot-monitor", Fgowl_screenshot_monitor,
       Sgowl_screenshot_monitor, 0, 1, 0,
       doc: /* Capture a screenshot of MONITOR (or focused monitor).
MONITOR is a GowlMonitor object or nil for the focused monitor.
Returns a list (WIDTH HEIGHT DATA) where DATA is a unibyte string
of RGBA pixel data, or nil on failure. */)
  (Lisp_Object monitor)
{
  GError *err = NULL;
  GBytes *bytes;
  gint w, h;
  const gchar *name = NULL;

  GOWL_CHECK_RUNNING ();

  if (!NILP (monitor))
    {
      GowlMonitor *mon = gowl_resolve_monitor (monitor);
      struct wlr_output *output = gowl_monitor_get_wlr_output (mon);
      if (output != NULL)
        name = output->name;
    }

  bytes = gowl_compositor_screenshot_output (cmacs_gowl_compositor,
                                              name, &w, &h, &err);
  if (bytes == NULL)
    {
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  {
    gsize size;
    const guint8 *data = g_bytes_get_data (bytes, &size);
    Lisp_Object str = make_unibyte_string ((const char *) data, size);
    g_bytes_unref (bytes);
    return list3 (make_fixnum (w), make_fixnum (h), str);
  }
}


/* ══════════════════════════════════════════════════════════════════════
 * Clipboard
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-clipboard-get", Fgowl_clipboard_get,
       Sgowl_clipboard_get, 0, 0, 0,
       doc: /* Get the current Wayland clipboard text, or nil. */)
  (void)
{
  GowlSeat *seat;
  gchar *text;

  GOWL_CHECK_RUNNING ();
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat == NULL)
    return Qnil;
  text = gowl_seat_get_clipboard (seat);
  if (text == NULL)
    return Qnil;
  {
    Lisp_Object result = build_string (text);
    g_free (text);
    return result;
  }
}

DEFUN ("gowl-clipboard-set", Fgowl_clipboard_set,
       Sgowl_clipboard_set, 1, 1, 0,
       doc: /* Set the Wayland clipboard to TEXT. */)
  (Lisp_Object text)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (text);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_set_clipboard (seat, SSDATA (text));
  return Qnil;
}

DEFUN ("gowl-primary-selection-get", Fgowl_primary_selection_get,
       Sgowl_primary_selection_get, 0, 0, 0,
       doc: /* Get the current Wayland primary selection text, or nil. */)
  (void)
{
  GowlSeat *seat;
  gchar *text;

  GOWL_CHECK_RUNNING ();
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat == NULL)
    return Qnil;
  text = gowl_seat_get_primary_selection (seat);
  if (text == NULL)
    return Qnil;
  {
    Lisp_Object result = build_string (text);
    g_free (text);
    return result;
  }
}

DEFUN ("gowl-primary-selection-set", Fgowl_primary_selection_set,
       Sgowl_primary_selection_set, 1, 1, 0,
       doc: /* Set the Wayland primary selection to TEXT. */)
  (Lisp_Object text)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (text);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_set_primary_selection (seat, SSDATA (text));
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Rounded corners
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-set-corner-radius", Fgowl_set_corner_radius,
       Sgowl_set_corner_radius, 1, 1, 0,
       doc: /* Set the corner radius for rounded window borders.
RADIUS is a non-negative integer (pixels).  Requires the
roundcorners module to be enabled.
Returns t on success, signals `gowl-error' if the module is not loaded. */)
  (Lisp_Object radius)
{
  GHashTable *inner, *outer;
  GowlModuleManager *mgr;
  gchar radstr[16];

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (radius);

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);

  g_snprintf (radstr, sizeof (radstr), "%ld", (long) XFIXNAT (radius));

  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "radius", (gpointer) radstr);

  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "roundcorners", inner);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  /* Force re-render all clients */
  gowl_compositor_arrange (cmacs_gowl_compositor,
      gowl_compositor_get_monitors (cmacs_gowl_compositor)
          ? GOWL_MONITOR (gowl_compositor_get_monitors (
                cmacs_gowl_compositor)->data)
          : NULL);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  g_hash_table_unref (outer);
  g_hash_table_unref (inner);

  return Qt;
}

DEFUN ("gowl-corner-radius", Fgowl_corner_radius,
       Sgowl_corner_radius, 0, 0, 0,
       doc: /* Return the current corner radius, or nil if roundcorners
module is not active. */)
  (void)
{
  GowlModuleManager *mgr;
  GowlModule *mod;

  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  mod = gowl_module_manager_find_module (mgr, "roundcorners");
  if (mod == NULL || !GOWL_IS_CLIENT_DECORATOR (mod))
    return Qnil;

  return make_fixnum (
      gowl_client_decorator_get_corner_radius (
          GOWL_CLIENT_DECORATOR (mod)));
}


/* ══════════════════════════════════════════════════════════════════════
 * Clipboard sync (Wayland ↔ Emacs kill-ring)
 * ══════════════════════════════════════════════════════════════════════ */

/* Idle callback — runs on Emacs main thread via GMainContext. */
static gboolean
clipboard_push_idle (gpointer user_data)
{
  gchar *text = (gchar *)user_data;
  gchar *elisp;

  if (text == NULL || text[0] == '\0')
    {
      g_free (text);
      return G_SOURCE_REMOVE;
    }

  /* Escape text for embedding in a Lisp string literal:
     backslash and double-quote need escaping. */
  {
    GString *esc = g_string_sized_new (strlen (text) + 16);
    const gchar *p;

    for (p = text; *p != '\0'; p++)
      {
        if (*p == '\\' || *p == '"')
          g_string_append_c (esc, '\\');
        g_string_append_c (esc, *p);
      }

    elisp = g_strdup_printf (
        "(cmacs-gowl--on-clipboard-changed \"%s\")", esc->str);
    g_string_free (esc, TRUE);
  }
  cmacs_dispatch_eval (elisp, NULL);
  g_free (elisp);
  g_free (text);

  return G_SOURCE_REMOVE;
}

/* Async read completion — runs on compositor dispatch thread,
   called from the fd-watch callback inside gowl-seat.c.  @text is
   allocated by the async helper and transferred to us; hand it off
   to the Emacs idle callback which will g_free it. */
static void
on_clipboard_read_done (gchar *text, gpointer user_data)
{
  (void)user_data;
  if (text != NULL)
    g_idle_add (clipboard_push_idle, text);
}

/* Signal handler — runs on compositor dispatch thread.
   We MUST NOT read the clipboard synchronously here: the signal
   fires from inside on_request_set_sel before the wl dispatch cycle
   has flushed the wl_data_source.send event to the owning client,
   so a blocking read would deadlock (or, with the write end already
   closed by wlr, return EOF with no data).  Instead, schedule an
   async read via an fd watch — the fd-watch fires later in the same
   dispatch loop, after the client has been given a chance to write. */
static void
on_clipboard_changed (GowlSeat *seat, gpointer user_data)
{
  struct wl_event_loop *loop;
  struct wl_display *wl_dpy;

  (void)user_data;

  if (cmacs_gowl_compositor == NULL)
    return;
  wl_dpy = gowl_compositor_get_wl_display (cmacs_gowl_compositor);
  if (wl_dpy == NULL)
    return;
  loop = wl_display_get_event_loop (wl_dpy);
  if (loop == NULL)
    return;

  (void) gowl_seat_read_clipboard_async (seat, loop,
                                          on_clipboard_read_done, NULL);
}

static void
on_primary_selection_changed (GowlSeat *seat, gpointer user_data)
{
  struct wl_event_loop *loop;
  struct wl_display *wl_dpy;

  (void)user_data;

  if (cmacs_gowl_compositor == NULL)
    return;
  wl_dpy = gowl_compositor_get_wl_display (cmacs_gowl_compositor);
  if (wl_dpy == NULL)
    return;
  loop = wl_display_get_event_loop (wl_dpy);
  if (loop == NULL)
    return;

  (void) gowl_seat_read_primary_selection_async (seat, loop,
                                                  on_clipboard_read_done,
                                                  NULL);
}

DEFUN ("gowl-clipboard-watch", Fgowl_clipboard_watch,
       Sgowl_clipboard_watch, 0, 0, 0,
       doc: /* Start watching Wayland clipboard changes.
When a Wayland client copies text, it is pushed to the Emacs
kill-ring via `cmacs-gowl--on-clipboard-changed'.
Returns t if watching started, nil if already watching. */)
  (void)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();

  if (cmacs_clipboard_handler_id != 0)
    return Qnil;

  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat == NULL)
    return Qnil;

  cmacs_clipboard_handler_id =
    g_signal_connect (seat, "clipboard-changed",
                      G_CALLBACK (on_clipboard_changed), NULL);
  cmacs_psel_handler_id =
    g_signal_connect (seat, "primary-selection-changed",
                      G_CALLBACK (on_primary_selection_changed), NULL);

  return Qt;
}

DEFUN ("gowl-clipboard-unwatch", Fgowl_clipboard_unwatch,
       Sgowl_clipboard_unwatch, 0, 0, 0,
       doc: /* Stop watching Wayland clipboard changes.
Returns t if watching was stopped, nil if not watching. */)
  (void)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();

  if (cmacs_clipboard_handler_id == 0)
    return Qnil;

  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    {
      g_signal_handler_disconnect (seat, cmacs_clipboard_handler_id);
      g_signal_handler_disconnect (seat, cmacs_psel_handler_id);
    }

  cmacs_clipboard_handler_id = 0;
  cmacs_psel_handler_id = 0;

  return Qt;
}


/* ══════════════════════════════════════════════════════════════════════
 * Bar / Layer surface
 * ══════════════════════════════════════════════════════════════════════ */

/* ── Multi-bar helpers ─────────────────────────────────────────────
 *
 * The four DEFUNs below let Elisp inspect or change individual bar
 * slots (top / bottom).  POSITION is an optional symbol -- `top
 * (default), `bottom, or nil.
 *
 * Reads go through the bar provider's get_bar_insets vfunc, so
 * they always reflect the current state of the bar module.  Writes
 * go through gowl_module_manager_configure_all with a small
 * settings hash naming the slot via the "position" key, mirroring
 * what `(gowl-bar-configure '(("position" . "top") ...))' would do
 * from elisp -- this keeps a single source of truth for slot
 * dispatch in bar_configure().
 */

/* Translate an optional Lisp POSITION symbol to a "top"/"bottom"
   string.  Defaults to "top" if @position is nil or unrecognised. */
static const char *
bar_position_str (Lisp_Object position)
{
  if (EQ (position, intern ("bottom")))
    return "bottom";
  return "top";
}

/* Configure a single bar slot via the module manager.  Builds a
   one-shot settings hash with "position" + the named KEY = VALUE,
   then dispatches.  KEY/VALUE may be NULL to apply position alone
   (used by visibility wrappers that build the hash themselves). */
static void
bar_configure_slot (const char *position, const char *key, const char *value)
{
  GHashTable *inner, *outer;
  GowlModuleManager *mgr;

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return;

  inner = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (inner, (gpointer) "position", (gpointer) position);
  if (key != NULL && value != NULL)
    g_hash_table_insert (inner, (gpointer) key, (gpointer) value);
  outer = g_hash_table_new (g_str_hash, g_str_equal);
  g_hash_table_insert (outer, (gpointer) "bar", inner);

  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_module_manager_configure_all (mgr, outer);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  g_hash_table_unref (outer);
  g_hash_table_unref (inner);
}

DEFUN ("gowl-bar-height", Fgowl_bar_height,
       Sgowl_bar_height, 0, 1, 0,
       doc: /* Return the height in pixels of the bar at POSITION.
POSITION is `top' (default) or `bottom'.  Returns 0 if that slot
is not configured or has been hidden, or nil if the bar module
has no active provider. */)
  (Lisp_Object position)
{
  GowlModuleManager *mgr;
  gint top = 0, bottom = 0;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;

  gowl_module_manager_get_bar_insets (mgr, NULL, &top, &bottom);
  if (EQ (position, intern ("bottom")))
    return make_fixnum (bottom);
  return make_fixnum (top);
}

DEFUN ("gowl-set-bar-height", Fgowl_set_bar_height,
       Sgowl_set_bar_height, 1, 2, 0,
       doc: /* Set the bar height to HEIGHT pixels.
Optional POSITION selects which slot (`top' default or `bottom'). */)
  (Lisp_Object height, Lisp_Object position)
{
  char buf[32];
  const char *pos;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (height);
  pos = bar_position_str (position);
  snprintf (buf, sizeof (buf), "%ld", (long) XFIXNAT (height));
  bar_configure_slot (pos, "height", buf);
  return Qnil;
}

DEFUN ("gowl-bar-visible-p", Fgowl_bar_visible_p,
       Sgowl_bar_visible_p, 0, 1, 0,
       doc: /* Return non-nil if the bar at POSITION is visible.
POSITION is `top' (default) or `bottom'.  A slot is visible iff
its inset is greater than zero. */)
  (Lisp_Object position)
{
  GowlModuleManager *mgr;
  gint top = 0, bottom = 0;
  gint v;

  GOWL_CHECK_RUNNING ();
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return Qnil;

  gowl_module_manager_get_bar_insets (mgr, NULL, &top, &bottom);
  v = EQ (position, intern ("bottom")) ? bottom : top;
  return v > 0 ? Qt : Qnil;
}

DEFUN ("gowl-set-bar-visible", Fgowl_set_bar_visible,
       Sgowl_set_bar_visible, 1, 2, 0,
       doc: /* Set bar visibility.  Non-nil VISIBLE shows the bar.
Optional POSITION selects which slot (`top' default or `bottom').
Hiding releases the slot's surfaces but preserves its
configuration so a later show restores it. */)
  (Lisp_Object visible, Lisp_Object position)
{
  const char *pos;

  GOWL_CHECK_RUNNING ();
  pos = bar_position_str (position);
  bar_configure_slot (pos, "visible", NILP (visible) ? "false" : "true");
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Input injection (text)
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-send-text", Fgowl_send_text, Sgowl_send_text, 1, 1, 0,
       doc: /* Send synthetic key events to type TEXT on the focused surface.
TEXT is a UTF-8 string.  Each character is mapped to an XKB keycode
and injected as a press/release pair.
Note: currently a stub that logs a warning; requires XKB keycode lookup. */)
  (Lisp_Object text)
{
  GowlSeat *seat;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (text);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    gowl_seat_send_text (seat, SSDATA (text));
  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Screenshots (client + region)
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-screenshot-client", Fgowl_screenshot_client,
       Sgowl_screenshot_client, 1, 1, 0,
       doc: /* Capture a screenshot of CLIENT.
Returns a list (WIDTH HEIGHT DATA) where DATA is a unibyte string
of RGBA pixel data, or nil on failure. */)
  (Lisp_Object client)
{
  GowlClient *c;
  GError *err = NULL;
  GBytes *bytes;
  gint w, h;

  GOWL_CHECK_RUNNING ();
  c = gowl_resolve_client (client);

  bytes = gowl_compositor_screenshot_client (cmacs_gowl_compositor,
                                              c, &w, &h, &err);
  if (bytes == NULL)
    {
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  {
    gsize size;
    const guint8 *data = g_bytes_get_data (bytes, &size);
    Lisp_Object str = make_unibyte_string ((const char *) data, size);
    g_bytes_unref (bytes);
    return list3 (make_fixnum (w), make_fixnum (h), str);
  }
}

DEFUN ("gowl-screenshot-region", Fgowl_screenshot_region,
       Sgowl_screenshot_region, 4, 5, 0,
       doc: /* Capture a region from a monitor screenshot.
X, Y, W, H define the crop rectangle.  MONITOR is a GowlMonitor
object or nil for the focused monitor.
Returns a list (WIDTH HEIGHT DATA) with the cropped RGBA pixel data. */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object w, Lisp_Object h,
   Lisp_Object monitor)
{
  GError *err = NULL;
  GBytes *bytes;
  gint sw, sh;
  const gchar *name = NULL;
  EMACS_INT rx, ry, rw, rh;

  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  rx = XFIXNUM (x);
  ry = XFIXNUM (y);
  rw = XFIXNUM (w);
  rh = XFIXNUM (h);

  if (!NILP (monitor))
    {
      GowlMonitor *mon = gowl_resolve_monitor (monitor);
      struct wlr_output *output = gowl_monitor_get_wlr_output (mon);
      if (output != NULL)
        name = output->name;
    }

  bytes = gowl_compositor_screenshot_output (cmacs_gowl_compositor,
                                              name, &sw, &sh, &err);
  if (bytes == NULL)
    {
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  /* Crop the region */
  {
    gsize size;
    const guint8 *src = g_bytes_get_data (bytes, &size);
    EMACS_INT row, src_stride, dst_stride;
    Lisp_Object str;
    unsigned char *dst;

    /* Clamp to screenshot bounds */
    if (rx < 0) rx = 0;
    if (ry < 0) ry = 0;
    if (rx + rw > sw) rw = sw - rx;
    if (ry + rh > sh) rh = ry - ry;
    if (rw <= 0 || rh <= 0)
      {
        g_bytes_unref (bytes);
        return Qnil;
      }

    src_stride = sw * 4;
    dst_stride = rw * 4;
    str = make_uninit_string (rh * dst_stride);
    dst = (unsigned char *) SDATA (str);
    STRING_SET_UNIBYTE (str);

    for (row = 0; row < rh; row++)
      memcpy (dst + row * dst_stride,
              src + (ry + row) * src_stride + rx * 4,
              dst_stride);

    g_bytes_unref (bytes);
    return list3 (make_fixnum (rw), make_fixnum (rh), str);
  }
}


/* ══════════════════════════════════════════════════════════════════════
 * Screenshot & Recording (high-level)
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-screenshot", Fgowl_screenshot, Sgowl_screenshot, 0, 3, 0,
       doc: /* Take a screenshot and save as PNG.
Optional MODE is a symbol: `desktop' (default), `window', or `all'.
Optional PATH is the output file; nil uses ~/Pictures/Screenshots/.
Optional NO-CLIPBOARD non-nil skips clipboard copy.
Returns the saved file path as a string. */)
  (Lisp_Object mode, Lisp_Object path, Lisp_Object no_clipboard)
{
  GBytes *data = NULL;
  gint w = 0, h = 0;
  GError *err = NULL;
  g_autofree gchar *save_path = NULL;
  g_autofree gchar *dir = NULL;

  GOWL_CHECK_RUNNING ();

  /* MODE defaults to 'desktop when nil */
  if (NILP (mode))
    mode = intern_c_string ("desktop");
  else
    CHECK_SYMBOL (mode);

  /* Capture based on mode */
  if (EQ (mode, intern_c_string ("desktop")))
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      data = gowl_compositor_screenshot_output (cmacs_gowl_compositor,
                                                 NULL, &w, &h, &err);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }
  else if (EQ (mode, intern_c_string ("window")))
    {
      GowlClient *focused;

      pthread_mutex_lock (&cmacs_gowl_mutex);
      focused = gowl_compositor_get_focused_client (cmacs_gowl_compositor);
      if (focused != NULL)
        data = gowl_compositor_screenshot_client (cmacs_gowl_compositor,
                                                   focused, &w, &h, &err);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }
  else if (EQ (mode, intern_c_string ("all")))
    {
      pthread_mutex_lock (&cmacs_gowl_mutex);
      data = gowl_compositor_screenshot_all (cmacs_gowl_compositor,
                                              &w, &h, &err);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }
  else
    {
      xsignal1 (Qgowl_error,
                 build_string ("Unknown mode: use desktop, window, or all"));
    }

  if (data == NULL)
    {
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  /* Determine save path */
  if (STRINGP (path))
    {
      save_path = g_strdup (SSDATA (path));
      dir = g_path_get_dirname (save_path);
      g_mkdir_with_parents (dir, 0755);
    }
  else
    {
      char timebuf[64];
      time_t t = time (NULL);
      struct tm tm;
      const char *home = getenv ("HOME");

      localtime_r (&t, &tm);
      strftime (timebuf, sizeof (timebuf),
                "screenshot_%Y%m%d_%H%M%S", &tm);

      dir = g_strdup_printf ("%s/Pictures/Screenshots",
                             home ? home : "/tmp");
      g_mkdir_with_parents (dir, 0755);
      save_path = g_strdup_printf ("%s/%s.png", dir, timebuf);
    }

  /* Save PNG */
  if (!gowl_compositor_save_png (data, w, h, save_path, &err))
    {
      g_bytes_unref (data);
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  g_bytes_unref (data);
  return build_string (save_path);
}

DEFUN ("gowl-screenshot-save-png", Fgowl_screenshot_save_png,
       Sgowl_screenshot_save_png, 4, 4, 0,
       doc: /* Save RGBA pixel DATA as a PNG file.
WIDTH and HEIGHT are dimensions.  DATA is a unibyte string of RGBA
pixel data.  PATH is the output file path.
Returns t on success. */)
  (Lisp_Object width, Lisp_Object height, Lisp_Object data,
   Lisp_Object path)
{
  GBytes *bytes;
  GError *err = NULL;
  g_autofree gchar *dir = NULL;

  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  CHECK_STRING (data);
  CHECK_STRING (path);

  bytes = g_bytes_new_static (SDATA (data), SBYTES (data));

  dir = g_path_get_dirname (SSDATA (path));
  g_mkdir_with_parents (dir, 0755);

  if (!gowl_compositor_save_png (bytes,
                                  (gint) XFIXNAT (width),
                                  (gint) XFIXNAT (height),
                                  SSDATA (path), &err))
    {
      g_bytes_unref (bytes);
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  g_bytes_unref (bytes);
  return Qt;
}

DEFUN ("gowl-screenshot-all", Fgowl_screenshot_all,
       Sgowl_screenshot_all, 0, 0, 0,
       doc: /* Capture all monitors stitched together.
Returns a list (WIDTH HEIGHT DATA) where DATA is a unibyte string
of RGBA pixel data, or nil on failure. */)
  (void)
{
  GError *err = NULL;
  GBytes *bytes;
  gint w, h;

  GOWL_CHECK_RUNNING ();

  pthread_mutex_lock (&cmacs_gowl_mutex);
  bytes = gowl_compositor_screenshot_all (cmacs_gowl_compositor,
                                           &w, &h, &err);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  if (bytes == NULL)
    {
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  {
    gsize size;
    const guint8 *data = g_bytes_get_data (bytes, &size);
    Lisp_Object str = make_unibyte_string ((const char *) data, size);
    g_bytes_unref (bytes);
    return list3 (make_fixnum (w), make_fixnum (h), str);
  }
}

DEFUN ("gowl-record-start", Fgowl_record_start, Sgowl_record_start,
       0, 2, 0,
       doc: /* Start screen recording.
Optional MODE is a symbol: `desktop' (default), `window', or `all'.
Optional PATH is the output file; nil uses ~/Videos/Recordings/.
Returns the output file path.
Signals `gowl-error' if ffmpeg is not found or a recording is active. */)
  (Lisp_Object mode, Lisp_Object path)
{
  GowlModuleManager *mgr;
  GowlModule *mod;
  GError *err = NULL;
  GowlCaptureMode capture_mode;
  g_autofree gchar *save_path = NULL;
  gboolean ok;

  GOWL_CHECK_RUNNING ();

  /* MODE defaults to 'desktop when nil */
  if (NILP (mode))
    mode = intern_c_string ("desktop");
  else
    CHECK_SYMBOL (mode);

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  mod = gowl_module_manager_find_module (mgr, "recording");
  if (mod == NULL || !GOWL_IS_RECORDING_PROVIDER (mod))
    xsignal1 (Qgowl_error,
              build_string ("Recording module not loaded"));

  /* Map mode symbol to enum */
  if (EQ (mode, intern_c_string ("desktop")))
    capture_mode = GOWL_CAPTURE_MODE_DESKTOP;
  else if (EQ (mode, intern_c_string ("window")))
    capture_mode = GOWL_CAPTURE_MODE_WINDOW;
  else if (EQ (mode, intern_c_string ("all")))
    capture_mode = GOWL_CAPTURE_MODE_ALL;
  else
    xsignal1 (Qgowl_error,
              build_string ("Unknown mode: use desktop, window, or all"));

  /* Determine save path */
  if (STRINGP (path))
    {
      save_path = g_strdup (SSDATA (path));
    }
  else
    {
      char timebuf[64];
      time_t t = time (NULL);
      struct tm tm;
      const char *home = getenv ("HOME");
      g_autofree gchar *dir = NULL;

      localtime_r (&t, &tm);
      strftime (timebuf, sizeof (timebuf),
                "recording_%Y%m%d_%H%M%S", &tm);

      dir = g_strdup_printf ("%s/Videos/Recordings",
                             home ? home : "/tmp");
      g_mkdir_with_parents (dir, 0755);
      save_path = g_strdup_printf ("%s/%s.mp4", dir, timebuf);
    }

  pthread_mutex_lock (&cmacs_gowl_mutex);
  ok = gowl_recording_provider_start (
           GOWL_RECORDING_PROVIDER (mod),
           capture_mode, NULL, NULL,
           0, 0, 0, 0,
           save_path, &err);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  if (!ok)
    {
      if (err != NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qgowl_error, msg);
        }
      return Qnil;
    }

  return build_string (save_path);
}

DEFUN ("gowl-record-stop", Fgowl_record_stop, Sgowl_record_stop,
       0, 0, 0,
       doc: /* Stop the current screen recording.
Returns the output file path, or nil if not recording. */)
  (void)
{
  GowlModuleManager *mgr;
  GowlModule *mod;
  GError *err = NULL;
  g_autofree gchar *out_path = NULL;

  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  mod = gowl_module_manager_find_module (mgr, "recording");
  if (mod == NULL || !GOWL_IS_RECORDING_PROVIDER (mod))
    return Qnil;

  /* Fast cleanup (disconnect signal, close pipe) under the mutex. */
  pthread_mutex_lock (&cmacs_gowl_mutex);
  gowl_recording_provider_stop (GOWL_RECORDING_PROVIDER (mod),
                                 &out_path, &err);
  pthread_mutex_unlock (&cmacs_gowl_mutex);

  /* Wait for ffmpeg to finalize the file OUTSIDE the mutex.
   * waitpid can block for hundreds of milliseconds; holding the
   * compositor mutex during that time deadlocks the dispatch
   * thread which needs the mutex to run the Wayland event loop. */
  gowl_recording_provider_finalize (GOWL_RECORDING_PROVIDER (mod));

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgowl_error, msg);
    }

  if (out_path != NULL)
    return build_string (out_path);
  return Qnil;
}

DEFUN ("gowl-recording-p", Fgowl_recording_p, Sgowl_recording_p,
       0, 0, 0,
       doc: /* Return non-nil if a screen recording is in progress. */)
  (void)
{
  GowlModuleManager *mgr;
  GowlModule *mod;

  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  mod = gowl_module_manager_find_module (mgr, "recording");
  if (mod == NULL || !GOWL_IS_RECORDING_PROVIDER (mod))
    return Qnil;

  return gowl_recording_provider_is_recording (
             GOWL_RECORDING_PROVIDER (mod)) ? Qt : Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * Layer surfaces
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-list-layer-surfaces", Fgowl_list_layer_surfaces,
       Sgowl_list_layer_surfaces, 0, 1, 0,
       doc: /* Return a list of GowlLayerSurface GObjects on MONITOR.
MONITOR is a GowlMonitor object or nil for the focused monitor. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  GList *surfaces, *l;
  Lisp_Object result;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  surfaces = gowl_monitor_get_layer_surfaces (mon);
  result = Qnil;
  for (l = surfaces; l != NULL; l = l->next)
    {
      GowlLayerSurface *ls = GOWL_LAYER_SURFACE (l->data);
      result = Fcons (cmacs_gobject_wrap (G_OBJECT (ls)), result);
    }
  return Fnreverse (result);
}

DEFUN ("gowl-layer-surface-info", Fgowl_layer_surface_info,
       Sgowl_layer_surface_info, 1, 1, 0,
       doc: /* Return an alist of info about LAYER-SURFACE.
Keys: layer, mapped. */)
  (Lisp_Object layer_surface)
{
  GObject *obj;
  GowlLayerSurface *ls;

  obj = cmacs_gobject_unwrap (layer_surface);
  if (obj == NULL || !GOWL_IS_LAYER_SURFACE (obj))
    error ("Not a GowlLayerSurface");
  ls = GOWL_LAYER_SURFACE (obj);

  return list2 (
    Fcons (intern_c_string ("layer"),
           make_fixnum (gowl_layer_surface_get_layer (ls))),
    Fcons (intern_c_string ("mapped"),
           gowl_layer_surface_is_mapped (ls) ? Qt : Qnil));
}


/* ══════════════════════════════════════════════════════════════════════
 * Process info
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-client-process-info", Fgowl_client_process_info,
       Sgowl_client_process_info, 1, 1, 0,
       doc: /* Return process info for CLIENT as an alist.
Keys: pid, comm, cmdline, cwd.  Values are strings or integers.
Returns nil if the PID is unavailable. */)
  (Lisp_Object client)
{
  GowlClient *c;
  GowlProcessInfo *info;
  Lisp_Object result;

  GOWL_CHECK_RUNNING ();
  c = gowl_resolve_client (client);
  info = gowl_client_get_process_info (c);
  if (info == NULL)
    return Qnil;

  result = list4 (
    Fcons (intern_c_string ("pid"),
           make_fixnum ((EMACS_INT) info->pid)),
    Fcons (intern_c_string ("comm"),
           info->comm ? build_string (info->comm) : Qnil),
    Fcons (intern_c_string ("cmdline"),
           info->cmdline ? build_string (info->cmdline) : Qnil),
    Fcons (intern_c_string ("cwd"),
           info->cwd ? build_string (info->cwd) : Qnil));

  gowl_process_info_free (info);
  return result;
}


/* ══════════════════════════════════════════════════════════════════════
 * Init
 * ══════════════════════════════════════════════════════════════════════ */

void
syms_of_cmacs_gowl (void)
{
  DEFSYM (Qgowl_error, "gowl-error");
  DEFSYM (Qnormal, "normal");
  DEFSYM (Q90, "90");
  DEFSYM (Q180, "180");
  DEFSYM (Q270, "270");
  DEFSYM (Qflipped, "flipped");
  DEFSYM (Qflipped_90, "flipped-90");
  DEFSYM (Qflipped_180, "flipped-180");
  DEFSYM (Qflipped_270, "flipped-270");

  Fput (Qgowl_error, Qerror_conditions,
        Fcons (Qgowl_error, Fcons (Qerror, Qnil)));
  Fput (Qgowl_error, Qerror_message,
        build_string ("Gowl compositor error"));

  DEFVAR_BOOL ("gowl-early-started", gowl_early_started,
               doc: /* Non-nil if the gowl compositor was started via --gowl.
The elisp layer uses this to auto-enable `cmacs-gowl-mode'. */);
  gowl_early_started = cmacs_gowl_compositor != NULL;

  /* Lifecycle */
  defsubr (&Sgowl_start);
  defsubr (&Sgowl_stop);
  defsubr (&Sgowl_running_p);
  defsubr (&Sgowl_socket_name);

  /* Prefix-key focus redirect */
  defsubr (&Sgowl_grant_focus_to_emacs);
  defsubr (&Sgowl_return_focus_to_embed);
  defsubr (&Sgowl_focus_redirect_active_p);
  defsubr (&Sgowl_focus_redirect_sticky_p);
  defsubr (&Sgowl_set_prefix_key_policy);

  /* Session save/restore */
  defsubr (&Sgowl_session_save);
  defsubr (&Sgowl_session_restore);

  /* App buffer support */
  defsubr (&Sgowl_client_set_geometry);
  defsubr (&Sgowl_client_add_mirror);
  defsubr (&Sgowl_client_update_mirror);
  defsubr (&Sgowl_client_remove_mirror);
  defsubr (&Sgowl_client_list_mirrors);

  /* Workspaces */
  defsubr (&Sgowl_workspace_provider_installed_p);
  defsubr (&Sgowl_install_frame_workspace_manager);
  defsubr (&Sgowl_uninstall_workspace_provider);
  defsubr (&Sgowl_workspace_create);
  defsubr (&Sgowl_workspace_switch);
  defsubr (&Sgowl_workspace_destroy);
  defsubr (&Sgowl_workspace_current);
  defsubr (&Sgowl_workspace_list);

  /* GObject accessors for full GI runtime control */
  defsubr (&Sgowl_compositor);
  defsubr (&Sgowl_config_object);
  defsubr (&Sgowl_module_manager);
  defsubr (&Sgowl_seat);
  defsubr (&Sgowl_cursor);
  defsubr (&Sgowl_keyboard_group);
  defsubr (&Sgowl_idle_manager);
  defsubr (&Sgowl_bar);

  /* Client management */
  defsubr (&Sgowl_list_clients);
  defsubr (&Sgowl_client_count);
  defsubr (&Sgowl_focused_client);
  defsubr (&Sgowl_focus_client);
  defsubr (&Sgowl_close_client);
  defsubr (&Sgowl_client_info);
  defsubr (&Sgowl_move_client);
  defsubr (&Sgowl_resize_client);
  defsubr (&Sgowl_set_tags);
  defsubr (&Sgowl_toggle_client_floating);
  defsubr (&Sgowl_set_client_floating);
  defsubr (&Sgowl_toggle_client_fullscreen);
  defsubr (&Sgowl_set_client_urgent);
  defsubr (&Sgowl_move_client_to_monitor);
  defsubr (&Sgowl_client_pid);
  defsubr (&Sgowl_find_client);

  defsubr (&Sgowl_set_client_border_width);
  defsubr (&Sgowl_set_client_visible);
  defsubr (&Sgowl_arrange);
  defsubr (&Sgowl_prefloat_pid);
  defsubr (&Sgowl_pretag_pid);
  defsubr (&Sgowl_reparent_client);
  defsubr (&Sgowl_set_client_embedded);
  defsubr (&Sgowl_client_border_width);
  defsubr (&Sgowl_emacs_client);
  defsubr (&Sgowl_embed_into);
  defsubr (&Sgowl_position_embedded);

  /* Embed view (GTK widget) */
  defsubr (&Sgowl_embed_create_view);
  defsubr (&Sgowl_embed_move_view);
  defsubr (&Sgowl_embed_destroy_view);
  defsubr (&Sgowl_embed_view_p);
  defsubr (&Sgowl_embed_focus);
  defsubr (&Sgowl_embed_set_visible);
  defsubr (&Sgowl_embed_expect_client);

#ifdef HAVE_XWIDGETS
  /* Xwidget-based embedding */
  defsubr (&Sgowl_make_xwidget);
#endif

  /* Process control */
  defsubr (&Sgowl_spawn);

  /* Monitor management */
  defsubr (&Sgowl_list_monitors);
  defsubr (&Sgowl_monitor_count);
  defsubr (&Sgowl_focused_monitor);
  defsubr (&Sgowl_find_monitor);
  defsubr (&Sgowl_monitor_info);
  defsubr (&Sgowl_monitor_modes);
  defsubr (&Sgowl_monitor_current_mode);
  defsubr (&Sgowl_set_monitor_mode);
  defsubr (&Sgowl_monitor_position);
  defsubr (&Sgowl_set_monitor_position);
  defsubr (&Sgowl_monitor_enabled_p);
  defsubr (&Sgowl_set_monitor_enabled);
  defsubr (&Sgowl_monitor_scale);
  defsubr (&Sgowl_set_monitor_scale);
  defsubr (&Sgowl_monitor_transform);
  defsubr (&Sgowl_set_monitor_transform);

  /* Tags */
  defsubr (&Sgowl_view_tags);
  defsubr (&Sgowl_toggle_tag_view);
  defsubr (&Sgowl_toggle_client_tag);
  defsubr (&Sgowl_tag_info);

  /* Layout */
  defsubr (&Sgowl_set_mfact);
  defsubr (&Sgowl_get_mfact);
  defsubr (&Sgowl_set_nmaster);
  defsubr (&Sgowl_get_nmaster);
  defsubr (&Sgowl_set_vsplit);
  defsubr (&Sgowl_get_vsplit);
  defsubr (&Sgowl_get_layout);
  defsubr (&Sgowl_set_layout);
  defsubr (&Sgowl_list_layouts);
  defsubr (&Sgowl_cycle_layout);
  defsubr (&Sgowl_scroll_by);

  /* Keybinds */
  defsubr (&Sgowl_add_keybind);
  defsubr (&Sgowl_list_keybinds);
  defsubr (&Sgowl_run_keybind);
  defsubr (&Sgowl_remove_keybind);
  defsubr (&Sgowl_clear_keybinds);

  /* Window rules */
  defsubr (&Sgowl_add_rule);
  defsubr (&Sgowl_add_rule_full);
  defsubr (&Sgowl_remove_rule);
  defsubr (&Sgowl_clear_rules);
  defsubr (&Sgowl_list_rules);
  defsubr (&Sgowl_float_toggle);
  defsubr (&Sgowl_module_dispatch_key);

  /* Dropdowns */
  defsubr (&Sgowl_add_dropdown);
  defsubr (&Sgowl_remove_dropdown);
  defsubr (&Sgowl_list_dropdowns);
  defsubr (&Sgowl_dropdown_toggle);
  defsubr (&Sgowl_dropdown_refresh);

  /* Session */
  defsubr (&Sgowl_lock);
  defsubr (&Sgowl_unlock);
  defsubr (&Sgowl_locked_p);
  defsubr (&Sgowl_reload_config);
  defsubr (&Sgowl_start_recording);
  defsubr (&Sgowl_drain_recording);
  defsubr (&Sgowl_stop_recording);
  defsubr (&Sgowl_recording_status);
  defsubr (&Sgowl_recording_active_p);
  defsubr (&Sgowl_config_get);
  defsubr (&Sgowl_config_generate_yaml);

  /* Modules */
  defsubr (&Sgowl_load_module);
  defsubr (&Sgowl_list_modules);
  defsubr (&Sgowl_load_modules_from_dir);
  defsubr (&Sgowl_enable_module);
  defsubr (&Sgowl_disable_module);
  defsubr (&Sgowl_configure_module);

  /* Wallpaper */
  defsubr (&Sgowl_set_wallpaper);
  defsubr (&Sgowl_wallpaper_info);
  defsubr (&Sgowl_set_client_alpha);
  defsubr (&Sgowl_set_all_alpha);
  defsubr (&Sgowl_set_focused_alpha);
  defsubr (&Sgowl_set_unfocused_alpha);
  defsubr (&Sgowl_alpha_info);
  defsubr (&Sgowl_set_gaps);
  defsubr (&Sgowl_gaps_info);
  defsubr (&Sgowl_configure_screenlock);
  defsubr (&Sgowl_scratchpad_toggle);
  defsubr (&Sgowl_usable_area);
  defsubr (&Sgowl_frame_origin);
  defsubr (&Sgowl_bar_enable);
  defsubr (&Sgowl_bar_disable);
  defsubr (&Sgowl_bar_configure);
  defsubr (&Sgowl_bar_redraw);
  defsubr (&Sgowl_bar_set_title);

  /* Swap / Zoom */
  defsubr (&Sgowl_swap_clients);
  defsubr (&Sgowl_zoom_client);

  /* Cursor / Keyboard */
  defsubr (&Sgowl_cursor_mode);
  defsubr (&Sgowl_set_cursor_mode);
  defsubr (&Sgowl_keyboard_repeat_rate);
  defsubr (&Sgowl_set_keyboard_repeat_rate);
  defsubr (&Sgowl_keyboard_repeat_delay);
  defsubr (&Sgowl_set_keyboard_repeat_delay);

  /* IPC */
  defsubr (&Sgowl_ipc_push_event);

  /* Input injection */
  defsubr (&Sgowl_send_key);
  defsubr (&Sgowl_send_text);
  defsubr (&Sgowl_send_mouse_move);
  defsubr (&Sgowl_send_mouse_button);
  defsubr (&Sgowl_send_scroll);

  /* Screenshots */
  defsubr (&Sgowl_screenshot_monitor);
  defsubr (&Sgowl_screenshot_client);
  defsubr (&Sgowl_screenshot_region);

  /* Clipboard */
  defsubr (&Sgowl_clipboard_get);
  defsubr (&Sgowl_clipboard_set);
  defsubr (&Sgowl_primary_selection_get);
  defsubr (&Sgowl_primary_selection_set);

  /* Bar / Layer surface */
  defsubr (&Sgowl_bar_height);
  defsubr (&Sgowl_set_bar_height);
  defsubr (&Sgowl_bar_visible_p);
  defsubr (&Sgowl_set_bar_visible);
  defsubr (&Sgowl_list_layer_surfaces);
  defsubr (&Sgowl_layer_surface_info);

  /* Process info */
  defsubr (&Sgowl_client_process_info);

  /* Rounded corners */
  defsubr (&Sgowl_set_corner_radius);
  defsubr (&Sgowl_corner_radius);

  /* Clipboard sync */
  defsubr (&Sgowl_clipboard_watch);
  defsubr (&Sgowl_clipboard_unwatch);

  /* Screenshot & Recording (high-level) */
  defsubr (&Sgowl_screenshot);
  defsubr (&Sgowl_screenshot_save_png);
  defsubr (&Sgowl_screenshot_all);
  defsubr (&Sgowl_record_start);
  defsubr (&Sgowl_record_stop);
  defsubr (&Sgowl_recording_p);
}

void
init_cmacs_gowl (void)
{
  /* Nothing to do here — the dispatch thread is started from
     --gowl in emacs.c or from gowl-start. */
}

#endif /* HAVE_CMACS_GOWL */
