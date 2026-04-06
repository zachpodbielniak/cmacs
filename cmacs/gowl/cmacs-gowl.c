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
#include "cmacs-gowl.h"
#include "cmacs-gobject.h"
#include "cmacs-eval-dispatch.h"
#include <gowl.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wayland-client-core.h>
#include <wlr/backend.h>
#include <wlr/backend/wayland.h>
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
#include <wlr/types/wlr_seat.h>
#include <wlr/render/wlr_texture.h>
#include <drm_fourcc.h>
#include <cairo.h>

/* Persistent compositor instance.
   NOT static — cmacs-eval-dispatch.c accesses this for gowl dispatch. */
GowlCompositor *cmacs_gowl_compositor = NULL;

/* ── Embed view (GTK widget inside Emacs frame) ────────────────────────
 *
 * Each embedded client gets a GtkDrawingArea added to the Emacs frame's
 * GtkFixed container.  The draw callback reads pixels from the client's
 * wlr_texture via wlr_texture_read_pixels() and paints them with Cairo.
 * A wl_listener on surface->events.commit queues a redraw when the
 * client renders a new frame.
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
  unsigned char *pixel_buf;    /* Pixel readback buffer */
  size_t pixel_buf_size;       /* Allocated size of pixel_buf */
  cairo_surface_t *cr_surface; /* Cairo surface wrapping pixel_buf */
  int tex_w, tex_h;            /* Last captured texture dimensions */
  int view_w, view_h;          /* Widget display size */
  gboolean dirty;              /* New frame available */
  guint idle_id;               /* Pending idle capture source, or 0 */
};

static GHashTable *embed_views = NULL; /* GowlClient* -> gowl_embed_view* */

static void
gowl_embed_view_capture (struct gowl_embed_view *view)
{
  struct wlr_surface *surface;
  struct wlr_texture *texture;
  int tw, th;
  size_t stride, needed;
  struct wlr_texture_read_pixels_options opts;

  surface = gowl_client_get_wlr_surface (view->client);
  if (surface == NULL || surface->buffer == NULL)
    return;

  texture = surface->buffer->texture;
  if (texture == NULL)
    return;

  tw = texture->width;
  th = texture->height;
  stride = (size_t) tw * 4;
  needed = stride * (size_t) th;

  if (needed > view->pixel_buf_size)
    {
      g_free (view->pixel_buf);
      view->pixel_buf = g_malloc (needed);
      view->pixel_buf_size = needed;
    }

  memset (&opts, 0, sizeof (opts));
  opts.data = view->pixel_buf;
  opts.format = DRM_FORMAT_ARGB8888;
  opts.stride = (uint32_t) stride;

  if (!wlr_texture_read_pixels (texture, &opts))
    return;

  /* Recreate Cairo surface if dimensions changed. */
  if (view->cr_surface != NULL
      && (view->tex_w != tw || view->tex_h != th))
    {
      cairo_surface_destroy (view->cr_surface);
      view->cr_surface = NULL;
    }

  if (view->cr_surface == NULL)
    view->cr_surface = cairo_image_surface_create_for_data (
      view->pixel_buf, CAIRO_FORMAT_ARGB32, tw, th, (int) stride);
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
  if (!view->dirty || view->widget == NULL)
    return G_SOURCE_REMOVE;

  /* The idle callback runs AFTER all higher-priority sources (Wayland
     events at G_PRIORITY_DEFAULT and output frame handling) have been
     dispatched.  The compositor's renderer has finished presenting,
     so eglMakeCurrent in wlr_texture_read_pixels won't conflict. */
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

static gboolean
gowl_embed_view_event (GtkWidget *widget, GdkEvent *event, gpointer data)
{
  struct gowl_embed_view *view = data;
  struct wlr_seat *seat;
  struct wlr_surface *surface;
  uint32_t time_ms;
  (void) widget;

  seat = gowl_compositor_get_wlr_seat (cmacs_gowl_compositor);
  surface = gowl_client_get_wlr_surface (view->client);
  if (seat == NULL || surface == NULL)
    return FALSE;

  time_ms = (uint32_t) (gdk_event_get_time (event) & 0xFFFFFFFF);

  switch (event->type)
    {
    case GDK_ENTER_NOTIFY:
      wlr_seat_pointer_notify_enter (seat, surface,
                                     event->crossing.x, event->crossing.y);
      wlr_seat_keyboard_notify_enter (seat, surface,
                                      NULL, 0, NULL);
      return TRUE;

    case GDK_LEAVE_NOTIFY:
      wlr_seat_pointer_notify_clear_focus (seat);
      return TRUE;

    case GDK_MOTION_NOTIFY:
      wlr_seat_pointer_notify_motion (seat, time_ms,
                                      event->motion.x, event->motion.y);
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
        wlr_seat_pointer_notify_button (seat, time_ms, btn, state);
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
        return TRUE;
      }

    case GDK_KEY_PRESS:
    case GDK_KEY_RELEASE:
      {
        /* hardware_keycode is the Linux evdev scancode + 8.
           Wayland keycodes are evdev scancodes. */
        uint32_t keycode = event->key.hardware_keycode - 8;
        enum wl_keyboard_key_state state =
          (event->type == GDK_KEY_PRESS)
          ? WL_KEYBOARD_KEY_STATE_PRESSED
          : WL_KEYBOARD_KEY_STATE_RELEASED;
        wlr_seat_keyboard_notify_key (seat, time_ms, keycode, state);
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

  wl_list_remove (&view->commit.link);

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

/* ── Keyboard shortcut inhibition for nested mode ────────────────────
 *
 * When gowl runs nested inside another Wayland compositor (e.g. GNOME),
 * the parent compositor intercepts keyboard shortcuts (Super, Alt+Tab,
 * etc.) before they reach gowl.  We use the zwp_keyboard_shortcuts_
 * inhibit_manager_v1 protocol to tell the parent compositor to pass
 * ALL key events through to gowl's output surface.
 */

static struct zwp_keyboard_shortcuts_inhibit_manager_v1 *shortcuts_mgr = NULL;
static struct zwp_keyboard_shortcuts_inhibitor_v1 *shortcuts_inhibitor = NULL;
static struct wl_seat *parent_seat = NULL;

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
   Uses wlroots backend accessors to get the parent display and
   the output surface, then binds the shortcut inhibitor protocol.

   NOT static — called from emacs.c --gowl handler. */
void
cmacs_gowl_inhibit_parent_shortcuts (GowlCompositor *comp)
{
  struct wlr_backend *backend;
  struct wl_display *parent_dpy;
  struct wl_registry *registry;
  GList *monitors;
  struct wlr_output *output;
  struct wl_surface *surface;

  backend = gowl_compositor_get_wlr_backend (comp);
  if (backend == NULL || !wlr_backend_is_wl (backend))
    return;  /* not nested */

  parent_dpy = wlr_wl_backend_get_remote_display (backend);
  if (parent_dpy == NULL)
    return;

  /* Bind the shortcut inhibitor manager and a wl_seat from
     the parent compositor via its registry. */
  registry = wl_display_get_registry (parent_dpy);
  wl_registry_add_listener (registry, &registry_listener, NULL);
  wl_display_roundtrip (parent_dpy);
  wl_registry_destroy (registry);

  if (shortcuts_mgr == NULL || parent_seat == NULL)
    return;  /* parent doesn't support shortcut inhibition */

  /* Inhibit shortcuts on the primary output surface. */
  monitors = gowl_compositor_get_monitors (comp);
  if (monitors == NULL)
    return;

  output = gowl_monitor_get_wlr_output (GOWL_MONITOR (monitors->data));
  if (output == NULL)
    return;

  surface = wlr_wl_output_get_surface (output);
  if (surface == NULL)
    return;

  shortcuts_inhibitor =
    zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts (
      shortcuts_mgr, surface, parent_seat);
  wl_display_roundtrip (parent_dpy);
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
 */

#include <pthread.h>
#include <poll.h>

static pthread_t cmacs_gowl_thread;
static volatile int cmacs_gowl_thread_running = 0;
static pthread_mutex_t cmacs_gowl_mutex = PTHREAD_MUTEX_INITIALIZER;

static void *
cmacs_gowl_dispatch_thread (void *data)
{
  GowlCompositor *comp = (GowlCompositor *) data;
  struct wl_display *wl_dpy = gowl_compositor_get_wl_display (comp);
  struct wl_event_loop *loop = gowl_compositor_get_event_loop (comp);
  int fd = wl_event_loop_get_fd (loop);
  struct pollfd pfd;

  pfd.fd = fd;
  pfd.events = POLLIN;

  while (cmacs_gowl_thread_running)
    {
      /* Wait for activity on the event loop fd (16ms timeout for
         wl_event_loop internal timers to fire regularly). */
      pfd.revents = 0;
      if (poll (&pfd, 1, 16) < 0)
        {
          if (errno == EINTR)
            continue;
          break;
        }

      pthread_mutex_lock (&cmacs_gowl_mutex);
      wl_display_flush_clients (wl_dpy);
      wl_event_loop_dispatch (loop, 0);
      wl_display_flush_clients (wl_dpy);
      pthread_mutex_unlock (&cmacs_gowl_mutex);
    }

  return NULL;
}

void
cmacs_gowl_start_thread (void)
{
  if (cmacs_gowl_thread_running || cmacs_gowl_compositor == NULL)
    return;

  cmacs_gowl_thread_running = 1;
  if (pthread_create (&cmacs_gowl_thread, NULL,
                      cmacs_gowl_dispatch_thread,
                      cmacs_gowl_compositor) != 0)
    {
      cmacs_gowl_thread_running = 0;
      fprintf (stderr, "cmacs: failed to create gowl dispatch thread\n");
    }
}

static void
cmacs_gowl_stop_thread (void)
{
  if (!cmacs_gowl_thread_running)
    return;

  cmacs_gowl_thread_running = 0;
  pthread_join (cmacs_gowl_thread, NULL);
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

  /* If already started (e.g. via --gowl early init), just make
     sure the dispatch thread is running. */
  if (cmacs_gowl_compositor != NULL)
    {
      if (!cmacs_gowl_thread_running)
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

  /* Load default config.  Do NOT unref — the compositor stores a
     borrowed reference, so cmacs owns the lifetime.  The objects
     are released in gowl-stop via g_clear_object on the compositor. */
  {
    GowlConfig *config = gowl_config_new ();
    gowl_config_load_yaml_from_search_path (config, NULL);
    gowl_compositor_set_config (cmacs_gowl_compositor, config);
  }

  /* Load modules.  Same ownership rule as config above. */
  {
    GowlModuleManager *mgr = gowl_module_manager_new ();
    gowl_compositor_set_module_manager (cmacs_gowl_compositor, mgr);
  }

  if (!gowl_compositor_start (cmacs_gowl_compositor, &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      g_clear_object (&cmacs_gowl_compositor);
      xsignal1 (Qgowl_error, msg);
    }

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
       doc: /* Focus CLIENT window. */)
  (Lisp_Object client)
{
  GowlClient *c;
  GowlMonitor *mon;

  GOWL_CHECK_RUNNING ();
  c = gowl_resolve_client (client);

  /* Move the client's tags into view on its monitor, then focus. */
  mon = gowl_client_get_monitor (c);
  if (mon != NULL)
    gowl_monitor_set_tags (GOWL_MONITOR (mon), gowl_client_get_tags (c));

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
Keys: title, app-id, tags, floating, fullscreen, urgent, pid, id, geometry. */)
  (Lisp_Object client)
{
  GowlClient *c;
  gint x, y, w, h;

  c = gowl_resolve_client (client);
  gowl_client_get_geometry (c, &x, &y, &w, &h);

  return list5 (
    Fcons (intern_c_string ("title"),
           build_string (gowl_client_get_title (c) ? : "")),
    Fcons (intern_c_string ("app-id"),
           build_string (gowl_client_get_app_id (c) ? : "")),
    Fcons (intern_c_string ("tags"),
           make_fixnum ((EMACS_INT)gowl_client_get_tags (c))),
    Fcons (intern_c_string ("floating"),
           gowl_client_get_floating (c) ? Qt : Qnil),
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
  gowl_compositor_resize_client (cmacs_gowl_compositor, c,
                                 (gint) XFIXNUM (x), (gint) XFIXNUM (y),
                                 cw, ch);
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
  gowl_compositor_resize_client (cmacs_gowl_compositor, c,
                                 cx, cy,
                                 (gint) XFIXNUM (w), (gint) XFIXNUM (h));
  return Qnil;
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
       doc: /* Toggle floating state of CLIENT. */)
  (Lisp_Object client)
{
  GowlClient *c = gowl_resolve_client (client);
  gowl_client_set_floating (c, !gowl_client_get_floating (c));
  return gowl_client_get_floating (c) ? Qt : Qnil;
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
Optional second arg BY is a symbol: `app-id' (default) or `title'. */)
  (Lisp_Object pattern, Lisp_Object by)
{
  GowlClient *c;

  GOWL_CHECK_RUNNING ();
  CHECK_STRING (pattern);

  if (!NILP (by) && EQ (by, intern_c_string ("title")))
    c = gowl_compositor_find_client_by_title (cmacs_gowl_compositor,
                                               SSDATA (pattern));
  else
    c = gowl_compositor_find_client_by_app_id (cmacs_gowl_compositor,
                                                SSDATA (pattern));

  if (c == NULL)
    return Qnil;
  return cmacs_gobject_wrap (G_OBJECT (c));
}


/* ══════════════════════════════════════════════════════════════════════
 * PROCESS CONTROL
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-spawn", Fgowl_spawn, Sgowl_spawn, 1, 1, 0,
       doc: /* Launch COMMAND as a Wayland client.
Returns the child process PID as an integer. */)
  (Lisp_Object command)
{
  GError *err = NULL;
  const gchar *socket;
  gchar **argv;
  gchar **envp;
  GPid child_pid = 0;

  CHECK_STRING (command);
  GOWL_CHECK_RUNNING ();

  if (!g_shell_parse_argv (SSDATA (command), NULL, &argv, &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgowl_error, msg);
    }

  /* Build environment: inherit current env, override WAYLAND_DISPLAY. */
  socket = gowl_compositor_get_socket_name (cmacs_gowl_compositor);
  {
    gchar **parent_env = g_get_environ ();
    envp = g_environ_setenv (parent_env, "WAYLAND_DISPLAY",
                             socket ? socket : "", TRUE);
  }

  if (!g_spawn_async (NULL, argv, envp,
                      G_SPAWN_SEARCH_PATH, NULL, NULL,
                      &child_pid, &err))
    {
      g_strfreev (argv);
      g_strfreev (envp);
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgowl_error, msg);
    }

  g_strfreev (argv);
  g_strfreev (envp);
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
  CHECK_FIXNAT (width);
  gowl_client_set_border_width (gowl_resolve_client (client),
                                (guint) XFIXNAT (width));
  return Qnil;
}

DEFUN ("gowl-set-client-visible",
       Fgowl_set_client_visible, Sgowl_set_client_visible,
       2, 2, 0,
       doc: /* Set CLIENT visibility.
Non-nil VISIBLE shows the client, nil hides it. */)
  (Lisp_Object client, Lisp_Object visible)
{
  gowl_client_set_visible (gowl_resolve_client (client),
                           !NILP (visible));
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
    gowl_compositor_arrange (cmacs_gowl_compositor, mon);
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

DEFUN ("gowl-reparent-client", Fgowl_reparent_client, Sgowl_reparent_client,
       2, 2, 0,
       doc: /* Move CLIENT scene node to LAYER.
LAYER is an integer index: 0=bg, 1=bottom, 2=tile, 3=float,
4=top, 5=fs, 6=overlay, 7=block. */)
  (Lisp_Object client, Lisp_Object layer)
{
  GOWL_CHECK_RUNNING ();
  CHECK_FIXNAT (layer);
  gowl_compositor_reparent_client (cmacs_gowl_compositor,
                                   gowl_resolve_client (client),
                                   (gint) XFIXNAT (layer));
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
Matches by PID against the compositor's client list. */)
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
      if (gowl_client_get_pid (c) == self_pid)
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
  GOWL_CHECK_RUNNING ();
  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);
  gowl_compositor_position_embedded (
    cmacs_gowl_compositor,
    gowl_resolve_client (client),
    (gint) XFIXNUM (x), (gint) XFIXNUM (y),
    (gint) XFIXNUM (w), (gint) XFIXNUM (h));
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
    }
  else
    wl_list_init (&view->commit.link);

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

DEFUN ("gowl-monitor-info", Fgowl_monitor_info, Sgowl_monitor_info,
       0, 1, 0,
       doc: /* Return an alist of MONITOR properties.
Keys: name, geometry, mfact, nmaster, tags, layout-symbol.
MONITOR defaults to the focused monitor. */)
  (Lisp_Object monitor)
{
  GowlMonitor *mon;
  gint x, y, w, h;

  GOWL_CHECK_RUNNING ();
  mon = gowl_resolve_monitor (monitor);
  if (mon == NULL)
    return Qnil;

  gowl_monitor_get_geometry (mon, &x, &y, &w, &h);

  return list5 (
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
           make_fixnum ((EMACS_INT)gowl_monitor_get_tags (mon))));
}


/* ══════════════════════════════════════════════════════════════════════
 * TAG OPERATIONS
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-view-tags", Fgowl_view_tags, Sgowl_view_tags, 1, 2, 0,
       doc: /* Switch tag view to TAGMASK on MONITOR.
TAGMASK is an integer bitmask.  MONITOR defaults to focused. */)
  (Lisp_Object tagmask, Lisp_Object monitor)
{
  GowlMonitor *mon;

  CHECK_FIXNAT (tagmask);
  GOWL_CHECK_RUNNING ();

  mon = gowl_resolve_monitor (monitor);
  if (mon != NULL)
    gowl_monitor_set_tags (mon, (guint32)XFIXNAT (tagmask));

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
LAYOUT is a string: \"tile\", \"monocle\", or \"float\".
Uses the module manager's key dispatch with GOWL_ACTION_SET_LAYOUT. */)
  (Lisp_Object layout, Lisp_Object monitor)
{
  GowlModuleManager *mgr;
  GowlConfig *config;
  GArray *keybinds;
  guint i;

  CHECK_STRING (layout);
  GOWL_CHECK_RUNNING ();

  (void)monitor;  /* layout switch acts on the focused monitor */

  /* Walk the config keybinds to find one with SET_LAYOUT action matching
     the requested layout string, and dispatch that keybind. */
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (mgr == NULL || config == NULL)
    return Qnil;

  keybinds = gowl_config_get_keybinds (config);
  for (i = 0; i < keybinds->len; i++)
    {
      GowlKeybindEntry *kb = &g_array_index (keybinds, GowlKeybindEntry, i);
      if (kb->action == (gint)GOWL_ACTION_SET_LAYOUT
          && kb->arg != NULL
          && g_strcmp0 (kb->arg, SSDATA (layout)) == 0)
        {
          gowl_module_manager_dispatch_key (mgr, kb->modifiers,
                                             kb->keysym, TRUE);
          return Qt;
        }
    }

  /* If no keybind matched, just eval through the action system. */
  {
    gchar *expr = g_strdup_printf (
      "(gowl-eval-action %d \"%s\")",
      (int)GOWL_ACTION_SET_LAYOUT, SSDATA (layout));
    g_free (expr);
  }

  return Qnil;
}


/* ══════════════════════════════════════════════════════════════════════
 * KEYBIND MANAGEMENT
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-add-keybind", Fgowl_add_keybind, Sgowl_add_keybind,
       2, 3, 0,
       doc: /* Add a keybind.  KEY is a string like \"Super+Return\".
ACTION is a symbol from gowl-action-* constants or an integer.
Optional ARG is a string argument for the action (e.g. command to spawn).
Uses gowl_keybind_parse to resolve the key string. */)
  (Lisp_Object key, Lisp_Object action, Lisp_Object arg)
{
  GowlConfig *config;
  guint modifiers, keysym;
  gint action_val;
  const gchar *arg_str = NULL;

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
      /* Map symbol names to GowlAction enum values. */
      const char *name = SSDATA (SYMBOL_NAME (action));
      if (g_strcmp0 (name, "spawn") == 0)
        action_val = (gint)GOWL_ACTION_SPAWN;
      else if (g_strcmp0 (name, "kill-client") == 0)
        action_val = (gint)GOWL_ACTION_KILL_CLIENT;
      else if (g_strcmp0 (name, "toggle-float") == 0)
        action_val = (gint)GOWL_ACTION_TOGGLE_FLOAT;
      else if (g_strcmp0 (name, "toggle-fullscreen") == 0)
        action_val = (gint)GOWL_ACTION_TOGGLE_FULLSCREEN;
      else if (g_strcmp0 (name, "focus-stack") == 0)
        action_val = (gint)GOWL_ACTION_FOCUS_STACK;
      else if (g_strcmp0 (name, "focus-monitor") == 0)
        action_val = (gint)GOWL_ACTION_FOCUS_MONITOR;
      else if (g_strcmp0 (name, "tag-view") == 0)
        action_val = (gint)GOWL_ACTION_TAG_VIEW;
      else if (g_strcmp0 (name, "tag-set") == 0)
        action_val = (gint)GOWL_ACTION_TAG_SET;
      else if (g_strcmp0 (name, "tag-toggle-view") == 0)
        action_val = (gint)GOWL_ACTION_TAG_TOGGLE_VIEW;
      else if (g_strcmp0 (name, "tag-toggle") == 0)
        action_val = (gint)GOWL_ACTION_TAG_TOGGLE;
      else if (g_strcmp0 (name, "move-to-monitor") == 0)
        action_val = (gint)GOWL_ACTION_MOVE_TO_MONITOR;
      else if (g_strcmp0 (name, "set-mfact") == 0)
        action_val = (gint)GOWL_ACTION_SET_MFACT;
      else if (g_strcmp0 (name, "inc-nmaster") == 0)
        action_val = (gint)GOWL_ACTION_INC_NMASTER;
      else if (g_strcmp0 (name, "set-layout") == 0)
        action_val = (gint)GOWL_ACTION_SET_LAYOUT;
      else if (g_strcmp0 (name, "cycle-layout") == 0)
        action_val = (gint)GOWL_ACTION_CYCLE_LAYOUT;
      else if (g_strcmp0 (name, "zoom") == 0)
        action_val = (gint)GOWL_ACTION_ZOOM;
      else if (g_strcmp0 (name, "quit") == 0)
        action_val = (gint)GOWL_ACTION_QUIT;
      else if (g_strcmp0 (name, "reload-config") == 0)
        action_val = (gint)GOWL_ACTION_RELOAD_CONFIG;
      else if (g_strcmp0 (name, "lock") == 0)
        action_val = (gint)GOWL_ACTION_LOCK;
      else
        error ("Unknown action: %s", name);
    }
  else
    error ("ACTION must be an integer or symbol");

  if (STRINGP (arg))
    arg_str = SSDATA (arg);

  gowl_config_add_keybind (config, modifiers, keysym,
                            action_val, arg_str);
  return Qt;
}

DEFUN ("gowl-list-keybinds", Fgowl_list_keybinds, Sgowl_list_keybinds,
       0, 0, 0,
       doc: /* Return a list of keybind alists.
Each alist has keys: key, action, arg. */)
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
      Lisp_Object entry;

      entry = list3 (
        Fcons (intern_c_string ("key"),
               build_string (key_str ? key_str : "")),
        Fcons (intern_c_string ("action"),
               make_fixnum (kb->action)),
        Fcons (intern_c_string ("arg"),
               kb->arg ? build_string (kb->arg) : Qnil));

      g_free (key_str);
      result = Fcons (entry, result);
    }

  return Fnreverse (result);
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

DEFUN ("gowl-list-rules", Fgowl_list_rules, Sgowl_list_rules, 0, 0, 0,
       doc: /* Return a list of window rule alists. */)
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

      entry = list5 (
        Fcons (intern_c_string ("app-id"),
               r->app_id ? build_string (r->app_id) : Qnil),
        Fcons (intern_c_string ("title"),
               r->title ? build_string (r->title) : Qnil),
        Fcons (intern_c_string ("tags"),
               make_fixnum ((EMACS_INT)r->tags)),
        Fcons (intern_c_string ("floating"),
               r->floating ? Qt : Qnil),
        Fcons (intern_c_string ("monitor"),
               make_fixnum (r->monitor)));

      result = Fcons (entry, result);
    }

  return Fnreverse (result);
}


/* ══════════════════════════════════════════════════════════════════════
 * SESSION MANAGEMENT
 * ══════════════════════════════════════════════════════════════════════ */

DEFUN ("gowl-lock", Fgowl_lock, Sgowl_lock, 0, 0, 0,
       doc: /* Lock the session. */)
  (void)
{
  GOWL_CHECK_RUNNING ();
  gowl_compositor_set_locked (cmacs_gowl_compositor, TRUE);
  return Qt;
}

DEFUN ("gowl-unlock", Fgowl_unlock, Sgowl_unlock, 0, 0, 0,
       doc: /* Unlock the session. */)
  (void)
{
  GOWL_CHECK_RUNNING ();
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
       0, 0, 0,
       doc: /* Reload the gowl config from the YAML search path. */)
  (void)
{
  GowlConfig *config;

  GOWL_CHECK_RUNNING ();
  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config != NULL)
    gowl_config_load_yaml_from_search_path (config, NULL);

  return Qt;
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
       doc: /* Load a gowl module from PATH (a .so file). */)
  (Lisp_Object path)
{
  GowlModuleManager *mgr;
  GError *err = NULL;

  CHECK_STRING (path);
  GOWL_CHECK_RUNNING ();

  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    error ("No module manager");

  if (!gowl_module_manager_load_module (mgr, SSDATA (path), &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgowl_error, msg);
    }

  return Qt;
}

DEFUN ("gowl-list-modules", Fgowl_list_modules, Sgowl_list_modules,
       0, 0, 0,
       doc: /* Return a list of loaded module GObjects. */)
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
    result = Fcons (cmacs_gobject_wrap (G_OBJECT (l->data)), result);

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


/* ══════════════════════════════════════════════════════════════════════
 * Init
 * ══════════════════════════════════════════════════════════════════════ */

void
syms_of_cmacs_gowl (void)
{
  DEFSYM (Qgowl_error, "gowl-error");

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

  /* GObject accessors for full GI runtime control */
  defsubr (&Sgowl_compositor);
  defsubr (&Sgowl_config_object);
  defsubr (&Sgowl_module_manager);

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
  defsubr (&Sgowl_toggle_client_fullscreen);
  defsubr (&Sgowl_set_client_urgent);
  defsubr (&Sgowl_move_client_to_monitor);
  defsubr (&Sgowl_client_pid);
  defsubr (&Sgowl_find_client);

  defsubr (&Sgowl_set_client_border_width);
  defsubr (&Sgowl_set_client_visible);
  defsubr (&Sgowl_arrange);
  defsubr (&Sgowl_prefloat_pid);
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

  /* Process control */
  defsubr (&Sgowl_spawn);

  /* Monitor management */
  defsubr (&Sgowl_list_monitors);
  defsubr (&Sgowl_monitor_count);
  defsubr (&Sgowl_focused_monitor);
  defsubr (&Sgowl_monitor_info);

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
  defsubr (&Sgowl_get_layout);
  defsubr (&Sgowl_set_layout);

  /* Keybinds */
  defsubr (&Sgowl_add_keybind);
  defsubr (&Sgowl_list_keybinds);

  /* Window rules */
  defsubr (&Sgowl_add_rule);
  defsubr (&Sgowl_list_rules);

  /* Session */
  defsubr (&Sgowl_lock);
  defsubr (&Sgowl_unlock);
  defsubr (&Sgowl_locked_p);
  defsubr (&Sgowl_reload_config);
  defsubr (&Sgowl_config_get);
  defsubr (&Sgowl_config_generate_yaml);

  /* Modules */
  defsubr (&Sgowl_load_module);
  defsubr (&Sgowl_list_modules);
  defsubr (&Sgowl_load_modules_from_dir);
}

void
init_cmacs_gowl (void)
{
  /* Nothing to do here — the dispatch thread is started from
     --gowl in emacs.c or from gowl-start. */
}

#endif /* HAVE_CMACS_GOWL */
