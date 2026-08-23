/* cmacs-libregnum-view.c --- per-buffer view (cmacs-internal half).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Holds the Lisp-side view state: buffer object, BGRA cairo
 * surface, redraw scheduling.  The actual raylib/libregnum
 * rendering lives in cmacs-libregnum-render.c (which can't share
 * a translation unit with cmacs internals because raylib's `Color'
 * conflicts with pgtkgui.h's `Color' typedef).  This file calls
 * the render helpers through their plain-C API. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "buffer.h"
#include "frame.h"
#include "window.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#ifdef HAVE_PGTK
#include "pgtkterm.h"   /* FRAME_GTK_WIDGET, for targeted overlay refresh */
#endif

#include <cairo.h>
#include <glib.h>

#ifdef HAVE_CMACS_LRGTERM
/* Defined in cmacs/lrgterm/cmacs-lrgterm.c; weak so a build without the lrg
   backend still links (then NULL -> we take the pgtk overlay path).  Under
   `emacs --lrg' the lrg present blits each view's FBO, so the view renders
   into its FBO and asks for a redisplay rather than compositing via cairo.  */
extern bool cmacs_lrgterm_active_p (void) __attribute__ ((weak));
/* Present the active lrg frame at once (re-expose + blit FBOs).  Used so a
   camera drag/zoom -- which re-renders the FBO without changing any text, so
   Emacs schedules no redisplay -- appears immediately, not only on the next
   click-driven redisplay.  */
extern void cmacs_lrgterm_present_now (void) __attribute__ ((weak));
#endif

/* ── View struct ───────────────────────────────────────────────── */

struct CmacsLibregnumView
{
  Lisp_Object       buffer;          /* GC-rooted via Vcmacs_libregnum__buffers */
  int               width, height;

  /* Render context owns the libregnum/raylib state. */
  CmacsLibregnumRenderCtx *render;

  /* CPU-side BGRA double buffer protected by frame_mtx.  The renderer
   * fills `back', then swaps back<->front under the mutex; the paint
   * hook reads `front'.  This keeps the mutex held only for the
   * pointer swap, not for the whole (slow) render+readback, so a
   * redisplay never blocks waiting for a frame to finish.  Backing
   * pixel storage is g_malloc0'd here and wrapped by the surfaces via
   * cairo_image_surface_create_for_data -- surfaces must be destroyed
   * before their backing data is freed. */
  GMutex            frame_mtx;
  cairo_surface_t  *front;          /* read by paint hook */
  cairo_surface_t  *back;           /* written by renderer */
  guint8           *front_data;
  guint8           *back_data;

  /* Scene-object id -> Lisp_Object payload key (the actual payload
   * lives in Vcmacs_libregnum__payloads). */
  GHashTable       *payloads;
  guint             view_id;

  /* Coalesced redraw flag. */
  gint              redraw_pending;

  /* Animation clock (see header).  `animated' opts the view into the
   * shared frame timer; `painted_gen' is the value of the global
   * animation generation counter at the last paint -- the timer treats
   * the view as on-screen while painted_gen is within a tick or two of
   * the current generation. */
  gboolean          animated;
  guint             painted_gen;
};

/* ── Registries ─────────────────────────────────────────────────── */

static GHashTable       *cmacs_libregnum__views     = NULL;
static guint             cmacs_libregnum__next_id   = 1;
static Lisp_Object       Vcmacs_libregnum__buffers;
static Lisp_Object       Vcmacs_libregnum__payloads;

/* Animation clock state (see cmacs_libregnum_view_set_animated). */
static guint             cmacs_libregnum__anim_timer_id = 0;
static guint             cmacs_libregnum__anim_interval_ms = 16; /* ~60 FPS */
static guint             cmacs_libregnum__anim_gen = 0;

void
cmacs_libregnum_view_registry_init (void)
{
  if (cmacs_libregnum__views) return;
  cmacs_libregnum__views = g_hash_table_new (g_direct_hash, g_direct_equal);
}

/* Exposed to syms_of_ for staticpro registration. */
Lisp_Object *cmacs_libregnum__buffers_root (void);
Lisp_Object *cmacs_libregnum__buffers_root (void)
{ return &Vcmacs_libregnum__buffers; }
Lisp_Object *cmacs_libregnum__payloads_root (void);
Lisp_Object *cmacs_libregnum__payloads_root (void)
{ return &Vcmacs_libregnum__payloads; }

/* True when no view has ever been attached (or all have been
 * destroyed).  Used by the overlay paint and input hooks as a fast
 * path: if no view exists, they bail before doing any work that
 * could re-enter Lisp from a GTK signal handler.  Calling Lisp
 * helpers (e.g. Fframe_root_window) from a GTK callback is
 * dangerous -- a CHECK_LIVE_FRAME signal would longjmp through
 * GLib's signal-emit machinery, bypassing emission_pop and
 * corrupting the global emission stack. */
gboolean
cmacs_libregnum_view_registry_empty_p (void)
{
  if (!cmacs_libregnum__views) return TRUE;
  return g_hash_table_size (cmacs_libregnum__views) == 0;
}

static void
ensure_lisp_tables (void)
{
  if (NILP (Vcmacs_libregnum__buffers))
    Vcmacs_libregnum__buffers  = CALLN (Fmake_hash_table, QCtest, Qeq);
  if (NILP (Vcmacs_libregnum__payloads))
    Vcmacs_libregnum__payloads = CALLN (Fmake_hash_table, QCtest, Qeql);
}

/* ── BGRA surface helpers ───────────────────────────────────────── */

static void
alloc_surface (CmacsLibregnumView *v, int w, int h)
{
  if (v->front)       cairo_surface_destroy (v->front);
  if (v->back)        cairo_surface_destroy (v->back);
  if (v->front_data)  g_free (v->front_data);
  if (v->back_data)   g_free (v->back_data);
  gsize sz = (gsize) w * h * 4;
  v->front_data = g_malloc0 (sz);
  v->back_data  = g_malloc0 (sz);
  v->front = cairo_image_surface_create_for_data (
    v->front_data, CAIRO_FORMAT_ARGB32, w, h, w * 4);
  v->back = cairo_image_surface_create_for_data (
    v->back_data, CAIRO_FORMAT_ARGB32, w, h, w * 4);
}

/* ── Redraw idle ─────────────────────────────────────────────────── */

#ifdef HAVE_PGTK
/* Does the window subtree rooted at W show BUFFER?  Plain C-struct
 * walk (no Lisp), same shape as the overlay paint hook. */
static bool
frame_shows_buffer (Lisp_Object w, Lisp_Object buffer)
{
  while (!NILP (w) && WINDOWP (w))
    {
      struct window *win = XWINDOW (w);
      Lisp_Object c = win->contents;
      if (WINDOWP (c))
        { if (frame_shows_buffer (c, buffer)) return true; }
      else if (BUFFERP (c) && EQ (c, buffer))
        return true;
      w = win->next;
    }
  return false;
}
#endif

/* Push the just-rendered frame to the screen.
 *
 * The libregnum buffer's text is static and entirely hidden behind the
 * BGRA blit, so Emacs's backing surface is already correct -- we only
 * need to re-composite the overlay.  Rather than force-window-update
 * (which provokes a full, ~35ms redisplay_internal every frame and was
 * the measured FPS ceiling), we invalidate just the GTK widget of each
 * frame showing the buffer with gtk_widget_queue_draw.  That re-runs
 * pgtk_handle_draw (-> the libregnum overlay paint hook) at the GTK
 * frame-clock rate, skipping redisplay entirely.  Runs on the main
 * thread from the redraw idle, so the GTK calls are safe.
 *
 * On non-pgtk builds (no overlay anyway) fall back to the old path. */
static void
notify_frame_ready (CmacsLibregnumView *v)
{
  if (NILP (v->buffer) || !BUFFERP (v->buffer)) return;
#ifdef HAVE_CMACS_LRGTERM
  /* Under the lrg backend there is no GTK widget and no cairo overlay; the
     lrg present blits the view's freshly-rendered FBO.  Present the frame
     directly: a camera drag/zoom re-renders the FBO but changes no text, so
     Emacs schedules no redisplay -- force-window-update would only mark the
     window dirty and the new view would not appear until the next redisplay
     (e.g. a click).  Presenting now (re-expose + blit FBO) shows it at once.
     Fall back to force-window-update if the lrg present symbol is absent.  */
  if (cmacs_lrgterm_active_p != NULL && cmacs_lrgterm_active_p ())
    {
      if (cmacs_lrgterm_present_now != NULL)
        cmacs_lrgterm_present_now ();
      else
        cmacs_dispatch_safe_call1 (intern ("force-window-update"), v->buffer);
      return;
    }
#endif
#ifdef HAVE_PGTK
  Lisp_Object tail, frame;
  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);
      if (FRAME_LIVE_P (f) && FRAME_PGTK_P (f)
          && FRAME_GTK_WIDGET (f)
          && frame_shows_buffer (f->root_window, v->buffer))
        gtk_widget_queue_draw (FRAME_GTK_WIDGET (f));
    }
#else
  cmacs_dispatch_safe_call1 (intern ("force-window-update"), v->buffer);
#endif
}

static gboolean
redraw_idle (gpointer user)
{
  CmacsLibregnumView *v = user;
  if (!g_atomic_int_compare_and_exchange (&v->redraw_pending, 1, 0))
    return G_SOURCE_REMOVE;
  if (!v->render) return G_SOURCE_REMOVE;

#ifdef HAVE_CMACS_LRGTERM
  /* lrg backend: render the scene INTO the FBO (the raylib GL context is
     current on the main thread) and ask for a redisplay; the lrg present
     blits fbo.texture.  No cairo readback/swap.  */
  if (cmacs_lrgterm_active_p != NULL && cmacs_lrgterm_active_p ())
    {
      if (cmacs_libregnum_render_ctx_render_into_fbo (v->render))
        {
          notify_frame_ready (v);
          if (cmacs_libregnum_render_ctx_focus_active (v->render))
            cmacs_libregnum_view_request_redraw (v);
        }
      return G_SOURCE_REMOVE;
    }
#endif

  /* Render into the back buffer WITHOUT holding frame_mtx: the paint
   * hook only ever touches `front', so the slow render+readback runs
   * concurrently with redisplay.  Lock only for the cheap swap. */
  if (v->back_data
      && cmacs_libregnum_render_ctx_render_to_bgra (
           v->render, v->back_data, v->width, v->height))
    {
      g_mutex_lock (&v->frame_mtx);
      cairo_surface_mark_dirty (v->back);
      cairo_surface_t *ts = v->front; v->front = v->back; v->back = ts;
      guint8 *td = v->front_data; v->front_data = v->back_data;
      v->back_data = td;
      g_mutex_unlock (&v->frame_mtx);

      notify_frame_ready (v);

      /* If a camera focus tween is in flight, keep the frames coming
       * until it converges (render_to_bgra advances it each frame). */
      if (cmacs_libregnum_render_ctx_focus_active (v->render))
        cmacs_libregnum_view_request_redraw (v);
    }
  return G_SOURCE_REMOVE;
}

/* ── View construction / destruction ───────────────────────────── */

CmacsLibregnumView *
cmacs_libregnum_view_new (Lisp_Object buffer, int width, int height)
{
  CHECK_BUFFER (buffer);
  cmacs_libregnum_view_registry_init ();
  ensure_lisp_tables ();

  gchar *err_msg = NULL;
  if (!cmacs_libregnum_render_window_acquire (&err_msg))
    {
      Lisp_Object msg = build_string (err_msg ? err_msg
                                              : "render init failed");
      g_free (err_msg);
      xsignal1 (intern ("cmacs-libregnum-error"), msg);
    }

  CmacsLibregnumView *v = g_new0 (CmacsLibregnumView, 1);
  v->buffer = buffer;
  v->width  = MAX (width,  16);
  v->height = MAX (height, 16);
  v->view_id = cmacs_libregnum__next_id++;
  g_mutex_init (&v->frame_mtx);
  v->payloads = g_hash_table_new (g_direct_hash, g_direct_equal);

  v->render = cmacs_libregnum_render_ctx_new (v->width, v->height);
  alloc_surface (v, v->width, v->height);

  g_hash_table_insert (cmacs_libregnum__views,
                       GUINT_TO_POINTER (v->view_id), v);
  Fputhash (buffer, make_uint (v->view_id), Vcmacs_libregnum__buffers);

  cmacs_libregnum_view_request_redraw (v);
  return v;
}

void
cmacs_libregnum_view_destroy (CmacsLibregnumView *v)
{
  if (!v) return;
  if (cmacs_libregnum__views)
    g_hash_table_remove (cmacs_libregnum__views,
                         GUINT_TO_POINTER (v->view_id));
  if (!NILP (Vcmacs_libregnum__buffers))
    Fremhash (v->buffer, Vcmacs_libregnum__buffers);

  cmacs_libregnum_render_ctx_free (v->render);

  g_mutex_lock (&v->frame_mtx);
  if (v->front) cairo_surface_destroy (v->front);
  if (v->back)  cairo_surface_destroy (v->back);
  g_free (v->front_data);
  g_free (v->back_data);
  g_mutex_unlock (&v->frame_mtx);
  g_mutex_clear (&v->frame_mtx);
  g_hash_table_destroy (v->payloads);
  g_free (v);

  cmacs_libregnum_render_window_release ();
}

CmacsLibregnumView *
cmacs_libregnum_view_for_buffer (Lisp_Object buffer)
{
  if (NILP (Vcmacs_libregnum__buffers)) return NULL;
  Lisp_Object id = Fgethash (buffer, Vcmacs_libregnum__buffers, Qnil);
  if (NILP (id)) return NULL;
  return g_hash_table_lookup (cmacs_libregnum__views,
                              GUINT_TO_POINTER (XFIXNUM (id)));
}

Lisp_Object
cmacs_libregnum_view_get_buffer (CmacsLibregnumView *v)
{
  return v ? v->buffer : Qnil;
}

void
cmacs_libregnum_view_request_redraw (CmacsLibregnumView *v)
{
  if (!v) return;
  if (g_atomic_int_compare_and_exchange (&v->redraw_pending, 0, 1))
    g_main_context_invoke (cmacs_glib_get_context (), redraw_idle, v);
}

/* ── Animation clock ─────────────────────────────────────────────── */

/* Shared frame timer.  Advances the generation counter, requests a
 * redraw for every animated view that is still on-screen (painted
 * within the last two generations), and self-terminates once no
 * animated view remains so an idle scene costs nothing. */
static gboolean
anim_tick (gpointer user)
{
  (void) user;
  cmacs_libregnum__anim_gen++;

  guint live_animated = 0;
  if (cmacs_libregnum__views)
    {
      GHashTableIter it;
      gpointer val;
      g_hash_table_iter_init (&it, cmacs_libregnum__views);
      while (g_hash_table_iter_next (&it, NULL, &val))
        {
          CmacsLibregnumView *v = val;
          if (!v->animated) continue;
          live_animated++;
          /* On-screen iff the paint hook stamped us recently.  The
           * redraw we request now provokes a redisplay that re-stamps
           * painted_gen, so a visible view stays "fresh"; a hidden one
           * falls behind and is skipped. */
          if (cmacs_libregnum__anim_gen - v->painted_gen <= 2)
            cmacs_libregnum_view_request_redraw (v);
        }
    }

  if (live_animated == 0)
    {
      cmacs_libregnum__anim_timer_id = 0;
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

void
cmacs_libregnum_view_set_animated (CmacsLibregnumView *v,
                                   gboolean animated,
                                   int target_fps)
{
  if (!v) return;
  v->animated = animated;
  if (animated)
    {
      if (target_fps > 0)
        cmacs_libregnum__anim_interval_ms = MAX (1, 1000 / target_fps);
      /* Seed visibility so the first tick renders without waiting for a
       * paint, then kick the clock if it isn't already running. */
      v->painted_gen = cmacs_libregnum__anim_gen;
      cmacs_libregnum_view_request_redraw (v);
      if (cmacs_libregnum__anim_timer_id == 0)
        {
          /* cmacs's GMainContext is a private context merged into
           * Emacs's pselect (cmacs-glib-loop.c), NOT the default one,
           * so the source must be attached to it explicitly --
           * g_timeout_add would target the default context and never
           * fire. */
          GMainContext *ctx = cmacs_glib_get_context ();
          GSource *src = g_timeout_source_new (
                           cmacs_libregnum__anim_interval_ms);
          g_source_set_callback (src, anim_tick, NULL, NULL);
          cmacs_libregnum__anim_timer_id = g_source_attach (src, ctx);
          g_source_unref (src);
        }
    }
  /* When turning off, leave the timer running: anim_tick removes itself
   * on the next tick once it sees no animated views remain. */
}

gboolean
cmacs_libregnum_view_get_animated (CmacsLibregnumView *v)
{
  return v ? v->animated : FALSE;
}

void
cmacs_libregnum_view_mark_painted (CmacsLibregnumView *v)
{
  if (!v) return;
  v->painted_gen = cmacs_libregnum__anim_gen;
}

cairo_surface_t *
cmacs_libregnum_view_lock_surface (CmacsLibregnumView *v)
{
  if (!v) return NULL;
  g_mutex_lock (&v->frame_mtx);
  return v->front;
}

void
cmacs_libregnum_view_unlock_surface (CmacsLibregnumView *v)
{
  if (!v) return;
  g_mutex_unlock (&v->frame_mtx);
}

/* ── Scene-builder accessors (return void* -- scene builders cast
 *    to libregnum types since they include libregnum.h). ───────── */

void *
cmacs_libregnum_view_get_renderer_raw (CmacsLibregnumView *v)
{ return v ? cmacs_libregnum_render_ctx_get_renderer (v->render) : NULL; }

void *
cmacs_libregnum_view_get_scene_raw (CmacsLibregnumView *v)
{ return v ? cmacs_libregnum_render_ctx_get_scene (v->render) : NULL; }

void *
cmacs_libregnum_view_get_camera_raw (CmacsLibregnumView *v)
{ return v ? cmacs_libregnum_render_ctx_get_camera (v->render) : NULL; }

void
cmacs_libregnum_view_set_camera_raw (CmacsLibregnumView *v, void *cam)
{
  if (!v) return;
  cmacs_libregnum_render_ctx_set_camera (v->render, cam);
  cmacs_libregnum_view_request_redraw (v);
}

CmacsLibregnumRenderCtx *
cmacs_libregnum_view_get_render_ctx (CmacsLibregnumView *v)
{ return v ? v->render : NULL; }

void
cmacs_libregnum_view_get_size (CmacsLibregnumView *v, int *w, int *h)
{
  if (!v) return;
  if (w) *w = v->width;
  if (h) *h = v->height;
}

void
cmacs_libregnum_view_resize (CmacsLibregnumView *v, int w, int h)
{
  if (!v) return;
  w = MAX (w, 16); h = MAX (h, 16);
  if (w == v->width && h == v->height) return;
  v->width = w; v->height = h;
  cmacs_libregnum_render_ctx_resize (v->render, w, h);
  g_mutex_lock (&v->frame_mtx);
  alloc_surface (v, w, h);
  g_mutex_unlock (&v->frame_mtx);
  cmacs_libregnum_view_request_redraw (v);
}

void
cmacs_libregnum_view_set_payload (CmacsLibregnumView *v,
                                  guint scene_object_id,
                                  Lisp_Object payload)
{
  if (!v) return;
  guint64 k = (guint64) v->view_id * 1000000000ULL + scene_object_id;
  Fputhash (make_uint (k), payload, Vcmacs_libregnum__payloads);
  g_hash_table_insert (v->payloads,
                       GUINT_TO_POINTER (scene_object_id),
                       GUINT_TO_POINTER (1));
}

Lisp_Object
cmacs_libregnum_view_get_payload (CmacsLibregnumView *v,
                                  guint scene_object_id)
{
  if (!v) return Qnil;
  guint64 k = (guint64) v->view_id * 1000000000ULL + scene_object_id;
  return Fgethash (make_uint (k), Vcmacs_libregnum__payloads, Qnil);
}

#endif /* HAVE_CMACS_LIBREGNUM */
