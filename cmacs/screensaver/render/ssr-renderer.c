/* ssr-renderer.c --- the screensaver render engine (child process core).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include "ssr-renderer.h"
#include "ssr-ipc.h"
#include "ssr-shm.h"
#include "cmacs-screensaver-proto.h"
#include "cmacs-libregnum-render.h"

#include <string.h>

#define SSR_FPS_MIN        1
#define SSR_FPS_MAX        240
#define SSR_FPS_DEFAULT    30
#define SSR_HEARTBEAT_MS   1000
#define SSR_IDLE_EXIT_MS   30000   /* self-exit after this long with no targets */

/* ---- per-target state ---------------------------------------------------- */

typedef struct
{
  int                      sink;       /* 0 = wallpaper, 1 = lock */
  gchar                   *mon;
  gchar                   *so;
  gchar                  **args;       /* NULL-terminated or NULL */
  int                      w, h;
  gboolean                 covered;
  CmacsLibregnumRenderCtx *ctx;        /* owns the loaded game module */
  SsrShm                  *shm;        /* frame ring (announced to Emacs) */
  uint32_t                 last_written;
} SsrTarget;

struct _SsrRenderer
{
  GObject     parent_instance;
  SsrIpc     *ipc;
  GMainLoop  *loop;
  GHashTable *targets;        /* "sink:mon" -> SsrTarget* */
  int         fps;
  gboolean    paused;
  gboolean    window_acquired;
  guint       render_source;
  guint       heartbeat_source;
  guint       idle_exit_source;
  gint64      hb_seq;
};

G_DEFINE_FINAL_TYPE (SsrRenderer, ssr_renderer, G_TYPE_OBJECT)

/* ---- helpers ------------------------------------------------------------- */

static gchar *
target_key (int sink, const gchar *mon)
{
  return g_strdup_printf ("%d:%s", sink, mon);
}

static gboolean
argv_equal (gchar **a, gchar **b)
{
  guint i;
  if (a == NULL && b == NULL)
    return TRUE;
  if (a == NULL || b == NULL)
    return FALSE;
  for (i = 0; a[i] != NULL && b[i] != NULL; i++)
    if (g_strcmp0 (a[i], b[i]) != 0)
      return FALSE;
  return a[i] == NULL && b[i] == NULL;
}

/* render_to_bgra returns rows bottom-up (glReadPixels origin lower-left); gowl
 * scene buffers are top-down, so flip in place -- identical to the orientation
 * the in-process pump produced (and which the user confirmed correct). */
static void
flip_rows_in_place (guint8 *buf, int w, int h)
{
  int stride = w * 4;
  guint8 *tmp;
  int y;

  if (buf == NULL || w <= 0 || h <= 1)
    return;
  tmp = g_malloc (stride);
  for (y = 0; y < h / 2; y++)
    {
      guint8 *top = buf + (gsize) y * stride;
      guint8 *bot = buf + (gsize) (h - 1 - y) * stride;
      memcpy (tmp, top, stride);
      memcpy (top, bot, stride);
      memcpy (bot, tmp, stride);
    }
  g_free (tmp);
}

static void
target_free (gpointer data)
{
  SsrTarget *t = data;
  if (t == NULL)
    return;
  if (t->ctx != NULL)
    {
      cmacs_libregnum_render_ctx_unload_game (t->ctx);
      cmacs_libregnum_render_ctx_free (t->ctx);
    }
  ssr_shm_free (t->shm);
  g_free (t->mon);
  g_free (t->so);
  g_strfreev (t->args);
  g_free (t);
}

/* ---- timers -------------------------------------------------------------- */

static gboolean ssr_render_tick (gpointer user);
static gboolean ssr_heartbeat_tick (gpointer user);
static gboolean ssr_idle_exit (gpointer user);

static void
ssr_restart_render_timer (SsrRenderer *self)
{
  guint interval;

  if (self->render_source != 0)
    {
      g_source_remove (self->render_source);
      self->render_source = 0;
    }
  if (g_hash_table_size (self->targets) == 0)
    return;
  interval = (guint) (1000 / self->fps);
  if (interval < 1)
    interval = 1;
  self->render_source = g_timeout_add (interval, ssr_render_tick, self);
}

static void
ssr_cancel_idle_exit (SsrRenderer *self)
{
  if (self->idle_exit_source != 0)
    {
      g_source_remove (self->idle_exit_source);
      self->idle_exit_source = 0;
    }
}

static void
ssr_maybe_idle_exit (SsrRenderer *self)
{
  if (g_hash_table_size (self->targets) > 0)
    return;
  ssr_cancel_idle_exit (self);
  self->idle_exit_source = g_timeout_add (SSR_IDLE_EXIT_MS, ssr_idle_exit, self);
}

static gboolean
ssr_idle_exit (gpointer user)
{
  SsrRenderer *self = user;
  self->idle_exit_source = 0;
  if (g_hash_table_size (self->targets) > 0)
    return G_SOURCE_REMOVE;            /* a target arrived; stay alive */
  ssr_ipc_send_stopped (self->ipc, "idle");
  g_main_loop_quit (self->loop);
  return G_SOURCE_REMOVE;
}

static gboolean
ssr_render_tick (gpointer user)
{
  SsrRenderer *self = user;
  GHashTableIter it;
  gpointer key, val;

  if (self->paused)
    return G_SOURCE_CONTINUE;

  g_hash_table_iter_init (&it, self->targets);
  while (g_hash_table_iter_next (&it, &key, &val))
    {
      SsrTarget *t = val;
      uint32_t idx;
      void *px;

      if (t->covered || t->ctx == NULL || t->shm == NULL)
        continue;                      /* covered/paused target burns no GPU */

      idx = scr_shm_writer_pick (t->shm->base, t->last_written);
      px = scr_shm_write_begin (t->shm->base, idx);
      if (cmacs_libregnum_render_ctx_render_to_bgra (t->ctx, px, t->w, t->h))
        {
          flip_rows_in_place (px, t->w, t->h);
          scr_shm_write_commit (t->shm->base, idx);
          t->last_written = idx;
        }
      else
        {
          scr_shm_write_abort (t->shm->base, idx);
        }
    }
  return G_SOURCE_CONTINUE;
}

static gboolean
ssr_heartbeat_tick (gpointer user)
{
  SsrRenderer *self = user;
  ssr_ipc_send_heartbeat (self->ipc, ++self->hb_seq);
  return G_SOURCE_CONTINUE;
}

/* ---- target management --------------------------------------------------- */

/* (Re)build a target's render context + frame buffer.  On success announces the
 * frame buffer (with its memfd) and stores the target; always sends a
 * load-result.  Returns the new target or NULL (already reported). */
static SsrTarget *
ssr_build_target (SsrRenderer *self, const ScrSetTarget *st)
{
  SsrTarget *t;
  char *lerr = NULL;
  GError *gerr = NULL;
  ScrLoadResult lr = { 0 };
  ScrFrameBuffer fb = { 0 };
  gchar *werr = NULL;

  lr.sink = st->sink;
  lr.mon = g_strdup (st->mon);

  if (!scr_shm_dims_valid ((uint32_t) st->w, (uint32_t) st->h))
    {
      lr.ok = FALSE;
      lr.err = g_strdup_printf ("invalid dimensions %dx%d", st->w, st->h);
      ssr_ipc_send_load_result (self->ipc, &lr);
      scr_load_result_clear (&lr);
      return NULL;
    }

  if (!self->window_acquired)
    {
      if (!cmacs_libregnum_render_window_acquire (&werr))
        {
          lr.ok = FALSE;
          lr.err = werr ? werr : g_strdup ("render window acquire failed");
          ssr_ipc_send_load_result (self->ipc, &lr);
          scr_load_result_clear (&lr);
          return NULL;
        }
      self->window_acquired = TRUE;
    }

  t = g_new0 (SsrTarget, 1);
  t->sink = st->sink;
  t->mon = g_strdup (st->mon);
  t->so = g_strdup (st->so);
  t->args = st->args ? g_strdupv (st->args) : NULL;
  t->w = st->w;
  t->h = st->h;
  t->covered = st->covered;
  t->last_written = SCR_SHM_SENTINEL;

  t->ctx = cmacs_libregnum_render_ctx_new (t->w, t->h);
  if (t->ctx == NULL
      || !cmacs_libregnum_render_ctx_load_game (
             t->ctx, t->so, (const char *const *) t->args, &lerr))
    {
      lr.ok = FALSE;
      lr.err = lerr ? lerr : g_strdup ("game module load failed");
      ssr_ipc_send_load_result (self->ipc, &lr);
      scr_load_result_clear (&lr);
      target_free (t);
      return NULL;
    }

  t->shm = ssr_shm_new ((uint32_t) t->w, (uint32_t) t->h, &gerr);
  if (t->shm == NULL)
    {
      lr.ok = FALSE;
      lr.err = g_strdup (gerr ? gerr->message : "shm alloc failed");
      g_clear_error (&gerr);
      ssr_ipc_send_load_result (self->ipc, &lr);
      scr_load_result_clear (&lr);
      target_free (t);
      return NULL;
    }

  /* Announce the frame buffer (carries the memfd) BEFORE the success
   * load-result, so Emacs has it mapped when told the load succeeded. */
  fb.sink = t->sink;
  fb.mon = t->mon;
  fb.w = t->w;
  fb.h = t->h;
  fb.stride = t->w * 4;
  fb.slots = (int) SCR_SHM_N_SLOTS;
  ssr_ipc_send_frame_buffer (self->ipc, &fb, t->shm->fd, NULL);

  lr.ok = TRUE;
  ssr_ipc_send_load_result (self->ipc, &lr);
  scr_load_result_clear (&lr);
  return t;
}

/* ---- IPC callbacks ------------------------------------------------------- */

static void
on_set_target (const ScrSetTarget *st, gpointer user)
{
  SsrRenderer *self = user;
  gchar *key = target_key (st->sink, st->mon);
  SsrTarget *existing = g_hash_table_lookup (self->targets, key);
  SsrTarget *t;

  if (existing != NULL
      && existing->w == st->w && existing->h == st->h
      && g_strcmp0 (existing->so, st->so) == 0
      && argv_equal (existing->args, st->args))
    {
      /* Same module + geometry: only the covered flag may have changed. */
      existing->covered = st->covered;
      g_free (key);
      return;
    }

  ssr_cancel_idle_exit (self);
  t = ssr_build_target (self, st);
  if (t == NULL)
    {
      g_free (key);
      return;          /* failure already reported; keep any existing target */
    }
  /* Replaces (and frees) any existing target for this key. */
  g_hash_table_insert (self->targets, key, t);
  ssr_restart_render_timer (self);
}

static void
on_remove_target (int sink, const gchar *mon, gpointer user)
{
  SsrRenderer *self = user;
  gchar *key = target_key (sink, mon);
  g_hash_table_remove (self->targets, key);
  g_free (key);
  if (g_hash_table_size (self->targets) == 0)
    {
      ssr_restart_render_timer (self);   /* removes the timer */
      ssr_maybe_idle_exit (self);
    }
}

static void
on_set_fps (int fps, gpointer user)
{
  SsrRenderer *self = user;
  if (fps < SSR_FPS_MIN)
    fps = SSR_FPS_DEFAULT;
  if (fps > SSR_FPS_MAX)
    fps = SSR_FPS_MAX;
  if (fps == self->fps)
    return;
  self->fps = fps;
  ssr_restart_render_timer (self);
}

static void
on_set_pause (gboolean paused, gpointer user)
{
  SsrRenderer *self = user;
  self->paused = paused;
}

static void
on_quit (gpointer user)
{
  SsrRenderer *self = user;
  g_main_loop_quit (self->loop);
}

/* ---- lifecycle ----------------------------------------------------------- */

static void
ssr_renderer_init (SsrRenderer *self)
{
  self->fps = SSR_FPS_DEFAULT;
  self->paused = FALSE;
  self->window_acquired = FALSE;
  self->hb_seq = 0;
  self->targets = g_hash_table_new_full (g_str_hash, g_str_equal,
                                         g_free, target_free);
}

static void
ssr_renderer_finalize (GObject *object)
{
  SsrRenderer *self = SSR_RENDERER (object);

  if (self->render_source != 0)
    g_source_remove (self->render_source);
  if (self->heartbeat_source != 0)
    g_source_remove (self->heartbeat_source);
  if (self->idle_exit_source != 0)
    g_source_remove (self->idle_exit_source);
  g_clear_pointer (&self->targets, g_hash_table_destroy);
  if (self->window_acquired)
    cmacs_libregnum_render_window_release ();
  g_clear_object (&self->ipc);

  G_OBJECT_CLASS (ssr_renderer_parent_class)->finalize (object);
}

static void
ssr_renderer_class_init (SsrRendererClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ssr_renderer_finalize;
}

SsrRenderer *
ssr_renderer_new (int ipc_fd, GMainLoop *loop)
{
  SsrRenderer *self = g_object_new (SSR_TYPE_RENDERER, NULL);
  SsrIpcCallbacks cb = {
    .set_target = on_set_target,
    .remove_target = on_remove_target,
    .set_fps = on_set_fps,
    .set_pause = on_set_pause,
    .quit = on_quit,
  };

  self->loop = loop;
  self->ipc = ssr_ipc_new (ipc_fd, &cb, self);
  if (self->ipc == NULL)
    {
      g_object_unref (self);
      return NULL;
    }
  self->heartbeat_source = g_timeout_add (SSR_HEARTBEAT_MS,
                                          ssr_heartbeat_tick, self);
  return self;
}
