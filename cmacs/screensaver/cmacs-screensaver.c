/* cmacs-screensaver.c --- render libregnum screensavers into gowl sinks.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The "buffer" mode is pure Elisp (cmacs-libregnum-play).  This file drives
 * the WALLPAPER and LOCK sinks: per enabled monitor it owns an off-screen
 * libregnum render context (a loaded game module), and a shared GLib timer
 * renders each context to a top-down BGRA frame and hands the raw pixels to
 * gowl via gowl_compositor_push_{wallpaper,lock}_frame().  gowl copies and
 * displays them; it never sees libregnum. */

#include <config.h>

#ifdef HAVE_CMACS_SCREENSAVER

#include "lisp.h"
#include "cmacs-screensaver.h"
#include "cmacs-libregnum-render.h"
#include "cmacs-glib-loop.h"

#include <glib.h>
#include <string.h>

#ifdef HAVE_CMACS_GOWL
#include "cmacs-gowl.h"
#include <gowl.h>
#endif

/* ---- per-monitor render state -------------------------------------------- */

typedef struct
{
  CmacsLibregnumRenderCtx *ctx;   /* owns a loaded game module */
  unsigned char           *bgra;  /* w*h*4 top-down BGRA scratch */
  int                      w, h;
} ScrMon;

typedef struct
{
  int          active;
  int          is_lock;           /* 1 = LOCK sink, 0 = WALLPAPER sink */
  char        *so_path;           /* owned */
  char       **argv;              /* owned, NULL-terminated, or NULL */
  int          pause_covered;     /* wallpaper: skip occluded monitors */
  GHashTable  *mons;              /* name -> ScrMon* */
} ScrSession;

static ScrSession sessions[2];          /* indexed by enum cmacs_screensaver_sink */
static guint      pump_source_id = 0;   /* shared frame-pump GSource id */
static int        pump_fps = 30;

static void scr_session_teardown (ScrSession *s);

/* ---- helpers ------------------------------------------------------------- */

static void
scr_mon_free (gpointer data)
{
  ScrMon *m = data;
  if (m == NULL)
    return;
  if (m->ctx != NULL)
    {
      cmacs_libregnum_render_ctx_unload_game (m->ctx);
      cmacs_libregnum_render_ctx_free (m->ctx);
    }
  g_free (m->bgra);
  g_free (m);
}

#ifdef HAVE_CMACS_GOWL

/* Push (or stop pushing) the frame for one monitor of a session. */
static void
scr_session_clear_gowl_one (ScrSession *s, GowlCompositor *comp,
                            const char *name)
{
  if (s->is_lock)
    gowl_compositor_clear_lock_frame (comp, name);
  else
    gowl_compositor_clear_wallpaper_frame (comp, name);
}

/* A snapshot of one enabled monitor's geometry, taken under the gowl lock so
 * the GL-heavy reconcile below can run without holding it (and without racing
 * the dispatch thread, which mutates the monitor list on hotplug). */
typedef struct
{
  char *name;
  int   x, y, w, h;
} ScrMonGeom;

/* Reconcile S->mons with the compositor's current enabled monitors: create a
 * render context for newly-appeared monitors, resize on geometry change, and
 * drop contexts for monitors that vanished.  Scene-graph touches (the gowl
 * monitor list + clear-frame) hold cmacs_gowl_lock; the slow GL ctx work runs
 * unlocked.  When ERR_OUT is non-NULL it receives (caller frees) the first
 * module-load error, if any. */
static void
scr_sync_monitors (ScrSession *s, GowlCompositor *comp, char **err_out)
{
  GArray *snap;              /* ScrMonGeom of currently-enabled monitors */
  GHashTable *live;          /* set of live names (borrowed from snap) */
  GHashTableIter it;
  gpointer key, val;
  GList *stale = NULL, *l;
  guint i;

  snap = g_array_new (FALSE, FALSE, sizeof (ScrMonGeom));
  live = g_hash_table_new (g_str_hash, g_str_equal);

  /* 1. Snapshot enabled monitors under the gowl lock. */
  cmacs_gowl_lock ();
  for (l = gowl_compositor_get_monitors (comp); l != NULL; l = l->next)
    {
      GowlMonitor *mon = l->data;
      const char *name;
      ScrMonGeom g;

      if (!gowl_monitor_get_enabled (mon))
        continue;
      name = gowl_monitor_get_name (mon);
      if (name == NULL)
        continue;
      gowl_monitor_get_geometry (mon, &g.x, &g.y, &g.w, &g.h);
      if (g.w <= 0 || g.h <= 0)
        continue;
      g.name = g_strdup (name);
      g_array_append_val (snap, g);
    }
  cmacs_gowl_unlock ();

  /* 2. Create/resize a render ctx per snapshot monitor (GL work, unlocked). */
  for (i = 0; i < snap->len; i++)
    {
      ScrMonGeom *g = &g_array_index (snap, ScrMonGeom, i);
      ScrMon *sm;

      g_hash_table_add (live, g->name);
      sm = g_hash_table_lookup (s->mons, g->name);
      if (sm == NULL)
        {
          char *lerr = NULL;
          sm = g_new0 (ScrMon, 1);
          sm->ctx = cmacs_libregnum_render_ctx_new (g->w, g->h);
          if (sm->ctx == NULL
              || !cmacs_libregnum_render_ctx_load_game (
                     sm->ctx, s->so_path,
                     (const char *const *) s->argv, &lerr))
            {
              if (err_out != NULL && *err_out == NULL)
                *err_out = lerr ? lerr : g_strdup ("render-ctx create failed");
              else
                g_free (lerr);
              scr_mon_free (sm);
              continue;
            }
          sm->w = g->w;
          sm->h = g->h;
          sm->bgra = g_malloc ((gsize) g->w * g->h * 4);
          g_hash_table_insert (s->mons, g_strdup (g->name), sm);
        }
      else if (sm->w != g->w || sm->h != g->h)
        {
          cmacs_libregnum_render_ctx_resize (sm->ctx, g->w, g->h);
          sm->w = g->w;
          sm->h = g->h;
          g_free (sm->bgra);
          sm->bgra = g_malloc ((gsize) g->w * g->h * 4);
          /* The old frame at the old size is now wrong -- drop it. */
          cmacs_gowl_lock ();
          scr_session_clear_gowl_one (s, comp, g->name);
          cmacs_gowl_unlock ();
        }
    }

  /* 3. Drop contexts for monitors that disappeared / were disabled. */
  g_hash_table_iter_init (&it, s->mons);
  while (g_hash_table_iter_next (&it, &key, &val))
    if (!g_hash_table_contains (live, key))
      stale = g_list_prepend (stale, key);
  for (l = stale; l != NULL; l = l->next)
    {
      cmacs_gowl_lock ();
      scr_session_clear_gowl_one (s, comp, l->data);
      cmacs_gowl_unlock ();
      g_hash_table_remove (s->mons, l->data);
    }
  g_list_free (stale);

  for (i = 0; i < snap->len; i++)
    g_free (g_array_index (snap, ScrMonGeom, i).name);
  g_array_free (snap, TRUE);
  g_hash_table_destroy (live);
}

/* render_to_bgra returns rows bottom-up (glReadPixels' origin is lower-left);
 * the in-buffer overlay flips that with a cairo matrix, but gowl scene buffers
 * are top-down, so we flip the rows here before pushing. */
static void
scr_flip_rows_in_place (unsigned char *buf, int w, int h)
{
  int stride = w * 4;
  unsigned char *tmp;
  int y;

  if (buf == NULL || w <= 0 || h <= 1)
    return;
  tmp = g_malloc (stride);
  for (y = 0; y < h / 2; y++)
    {
      unsigned char *top = buf + (gsize) y * stride;
      unsigned char *bot = buf + (gsize) (h - 1 - y) * stride;
      memcpy (tmp, top, stride);
      memcpy (top, bot, stride);
      memcpy (bot, tmp, stride);
    }
  g_free (tmp);
}

/* Render every monitor of S and push the frames to gowl. */
static void
scr_render_session (ScrSession *s, GowlCompositor *comp)
{
  GHashTableIter it;
  gpointer key, val;

  g_hash_table_iter_init (&it, s->mons);
  while (g_hash_table_iter_next (&it, &key, &val))
    {
      const char *name = key;
      ScrMon *m = val;

      /* Serialise the whole per-monitor render+push against the gowl dispatch
       * thread under its (recursive) lock.  raylib's GL context (GLX on X11)
       * and gowl's wlroots EGL context cannot be made current concurrently in
       * one process, so rendering off the lock produced a storm of
       * eglMakeCurrent "another window API has a current context" errors.
       * Holding the lock across the render serialises the two GL backends; it
       * costs a little compositor smoothness (mitigate with a lower
       * `cmacs-screensaver-fps'). */
      cmacs_gowl_lock ();
      if (s->is_lock || !s->pause_covered
          || !gowl_compositor_monitor_bg_covered (comp, name))
        {
          if (cmacs_libregnum_render_ctx_render_to_bgra (m->ctx, m->bgra,
                                                         m->w, m->h))
            {
              scr_flip_rows_in_place (m->bgra, m->w, m->h);
              if (s->is_lock)
                gowl_compositor_push_lock_frame (comp, name, m->bgra,
                                                 m->w, m->h, m->w * 4);
              else
                gowl_compositor_push_wallpaper_frame (comp, name, m->bgra,
                                                      m->w, m->h, m->w * 4);
            }
        }
      cmacs_gowl_unlock ();
    }
}

#endif /* HAVE_CMACS_GOWL */

static gboolean
scr_pump_tick (gpointer data)
{
  int any = 0;
  int i;
  (void) data;

#ifdef HAVE_CMACS_GOWL
  GowlCompositor *comp = cmacs_gowl_get_compositor ();
  if (comp != NULL)
    for (i = 0; i < 2; i++)
      if (sessions[i].active)
        {
          /* The lock background follows the compositor's lock state: when the
           * session unlocks (PAM success or gowl-unlock) stop rendering and
           * release, regardless of how the unlock happened. */
          gboolean locked;
          cmacs_gowl_lock ();
          locked = gowl_compositor_is_locked (comp);
          cmacs_gowl_unlock ();
          if (i == CMACS_SCREENSAVER_LOCK && !locked)
            {
              scr_session_teardown (&sessions[i]);
              cmacs_libregnum_render_window_release ();
              continue;
            }
          any = 1;
          scr_sync_monitors (&sessions[i], comp, NULL);
          scr_render_session (&sessions[i], comp);
        }
#else
  (void) i;
#endif

  if (!any)
    {
      pump_source_id = 0;
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

static void
scr_ensure_pump (void)
{
  GSource *src;
  guint interval;

  if (pump_source_id != 0)
    return;
  interval = (guint) (1000 / (pump_fps > 0 ? pump_fps : 30));
  if (interval < 1)
    interval = 1;
  src = g_timeout_source_new (interval);
  g_source_set_callback (src, scr_pump_tick, NULL, NULL);
  pump_source_id = g_source_attach (src, cmacs_glib_get_context ());
  g_source_unref (src);
}

static void
scr_session_teardown (ScrSession *s)
{
#ifdef HAVE_CMACS_GOWL
  GowlCompositor *comp = cmacs_gowl_get_compositor ();
  if (comp != NULL && s->mons != NULL)
    {
      GHashTableIter it;
      gpointer key, val;
      cmacs_gowl_lock ();
      g_hash_table_iter_init (&it, s->mons);
      while (g_hash_table_iter_next (&it, &key, &val))
        scr_session_clear_gowl_one (s, comp, key);
      cmacs_gowl_unlock ();
    }
#endif
  if (s->mons != NULL)
    g_hash_table_destroy (s->mons);
  s->mons = NULL;
  g_clear_pointer (&s->so_path, g_free);
  g_clear_pointer (&s->argv, g_strfreev);
  s->active = 0;
}

/* ---- public API ---------------------------------------------------------- */

char *
cmacs_screensaver_start (int sink, const char *so_path,
                         const char *const *argv, int fps, int pause_covered)
{
  ScrSession *s;

  if (sink < 0 || sink > 1 || so_path == NULL)
    return g_strdup ("invalid screensaver sink/module");

#ifndef HAVE_CMACS_GOWL
  (void) argv; (void) fps; (void) pause_covered;
  return g_strdup ("screensaver wallpaper/lock requires --with-cmacs-gowl");
#else
  {
    GowlCompositor *comp = cmacs_gowl_get_compositor ();
    char *werr = NULL;
    char *serr = NULL;

    if (comp == NULL)
      return g_strdup ("gowl compositor not running (start with --gowl)");

    /* Bring up the shared off-screen render window/engine. */
    if (!cmacs_libregnum_render_window_acquire (&werr))
      return werr ? werr : g_strdup ("could not acquire render window");

    if (fps > 0)
      pump_fps = fps;

    /* Replace any existing session on this sink. */
    s = &sessions[sink];
    if (s->active)
      scr_session_teardown (s);

    s->active = 1;
    s->is_lock = (sink == CMACS_SCREENSAVER_LOCK) ? 1 : 0;
    s->pause_covered = pause_covered ? 1 : 0;
    s->so_path = g_strdup (so_path);
    s->argv = (argv != NULL) ? g_strdupv ((char **) argv) : NULL;
    s->mons = g_hash_table_new_full (g_str_hash, g_str_equal,
                                     g_free, scr_mon_free);

    /* Build contexts now so a bad module reports synchronously. */
    scr_sync_monitors (s, comp, &serr);
    if (g_hash_table_size (s->mons) == 0)
      {
        scr_session_teardown (s);
        cmacs_libregnum_render_window_release ();
        return serr ? serr
                    : g_strdup ("no enabled monitor to render onto");
      }
    g_free (serr);

    scr_ensure_pump ();
    return NULL;
  }
#endif
}

void
cmacs_screensaver_stop (int sink)
{
  if (sink < 0 || sink > 1)
    return;
  if (!sessions[sink].active)
    return;
  scr_session_teardown (&sessions[sink]);
#ifdef HAVE_CMACS_GOWL
  cmacs_libregnum_render_window_release ();
#endif
  /* The pump removes itself on the next tick when no session is active. */
}

int
cmacs_screensaver_active (int sink)
{
  if (sink < 0 || sink > 1)
    return 0;
  return sessions[sink].active;
}

#endif /* HAVE_CMACS_SCREENSAVER */
