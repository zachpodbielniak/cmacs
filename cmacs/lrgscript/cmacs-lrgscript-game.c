/* cmacs-lrgscript-game.c --- LrgGameTemplate subclass that dispatches to elisp.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * CmacsLrgScriptGame is an LrgGameTemplate whose loop vfuncs
 * (post_startup / post_update / fixed_update / post_draw / shutdown /
 * on_focus_*) call into a set of Emacs Lisp hooks bound to a game id.  This
 * is what lets a whole libregnum game be authored in `.el' and driven in a
 * cmacs-libregnum buffer through the existing FBO game host.
 *
 * Includes <libregnum.h> (the template base + the render ctx host entry) and
 * never lisp.h; the actual elisp dispatch is delegated to
 * cmacs_lrgscript_game_dispatch() (lisp side), which applies the
 * waiting_for_input guard and per-frame error isolation. */

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include <libregnum.h>
#include <glib.h>

#include "cmacs-libregnum-render.h"   /* cmacs_libregnum_render_ctx_host_game */
#include "cmacs-lrgscript-game.h"

#define CMACS_TYPE_LRGSCRIPT_GAME (cmacs_lrgscript_game_get_type ())
G_DECLARE_FINAL_TYPE (CmacsLrgScriptGame, cmacs_lrgscript_game,
                      CMACS, LRGSCRIPT_GAME, LrgGameTemplate)

struct _CmacsLrgScriptGame
{
  LrgGameTemplate  parent_instance;
  guint64          game_id;
};

G_DEFINE_FINAL_TYPE (CmacsLrgScriptGame, cmacs_lrgscript_game,
                     LRG_TYPE_GAME_TEMPLATE)

/* ── Loop vfuncs -> elisp hooks ───────────────────────────────────── */

static void
cslg_post_startup (LrgGameTemplate *t)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_STARTUP, 0.0);
}

static void
cslg_post_update (LrgGameTemplate *t, gdouble delta)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_UPDATE, delta);
}

static void
cslg_fixed_update (LrgGameTemplate *t, gdouble fixed_delta)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_FIXED_UPDATE, fixed_delta);
}

static void
cslg_post_draw (LrgGameTemplate *t)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_DRAW, 0.0);
}

static void
cslg_shutdown (LrgGameTemplate *t)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_SHUTDOWN, 0.0);
}

static void
cslg_focus_gained (LrgGameTemplate *t)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_FOCUS_GAINED, 0.0);
}

static void
cslg_focus_lost (LrgGameTemplate *t)
{
  cmacs_lrgscript_game_dispatch (CMACS_LRGSCRIPT_GAME (t)->game_id,
                                 CMACS_LRGSCRIPT_HOOK_FOCUS_LOST, 0.0);
}

static void
cmacs_lrgscript_game_class_init (CmacsLrgScriptGameClass *klass)
{
  LrgGameTemplateClass *tc = LRG_GAME_TEMPLATE_CLASS (klass);

  tc->post_startup    = cslg_post_startup;
  tc->post_update     = cslg_post_update;
  tc->fixed_update    = cslg_fixed_update;
  tc->post_draw       = cslg_post_draw;
  tc->shutdown        = cslg_shutdown;
  tc->on_focus_gained = cslg_focus_gained;
  tc->on_focus_lost   = cslg_focus_lost;
}

static void
cmacs_lrgscript_game_init (CmacsLrgScriptGame *self)
{
  self->game_id = 0;
}

/* ── Public: build + host ─────────────────────────────────────────── */

gboolean
cmacs_lrgscript_game_run_in_ctx (gpointer render_ctx, guint64 game_id,
                                 const gchar *title, gint width, gint height,
                                 gchar **err)
{
  CmacsLrgScriptGame *g;

  if (render_ctx == NULL)
    {
      if (err) *err = g_strdup ("no render context for game");
      return FALSE;
    }

  g = g_object_new (CMACS_TYPE_LRGSCRIPT_GAME, NULL);
  g->game_id = game_id;
  if (title != NULL)
    lrg_game_template_set_title (LRG_GAME_TEMPLATE (g), title);
  if (width > 0 && height > 0)
    lrg_game_template_set_window_size (LRG_GAME_TEMPLATE (g), width, height);

  /* Transfers ownership of the game to the render ctx (or frees it on error). */
  return cmacs_libregnum_render_ctx_host_game (render_ctx,
                                               LRG_GAME_TEMPLATE (g), err);
}

#endif /* HAVE_CMACS_LRGSCRIPT */
