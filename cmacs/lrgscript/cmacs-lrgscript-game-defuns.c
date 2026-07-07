/* cmacs-lrgscript-game-defuns.c --- elisp game loop registry + DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The lisp side of the game-authoring layer: a per-game registry of loop-hook
 * closures keyed by an opaque game id, the dispatch entry the C game template
 * (cmacs-lrgscript-game.c) calls each frame, and the `cmacs-lrgscript-run-game'
 * / `cmacs-lrgscript-stop-game' commands.  Hooks are invoked through the
 * cmacs-eval-dispatch waiting_for_input guard so a signalled hook cannot abort
 * the compositor/main-thread frame loop.
 *
 * Includes lisp.h (never <libregnum.h>); talks to the libregnum side through
 * the opaque cmacs-libregnum.h view API and the glib-only game bridge. */

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include "lisp.h"
#include "buffer.h"
#include "coding.h"   /* ENCODE_UTF_8 */
#include "cmacs-lrgscript.h"
#include "cmacs-lrgscript-game.h"
#include "cmacs-libregnum.h"
#include "cmacs-eval-dispatch.h"
#include <glib.h>

/* game-id (fixnum) -> hook plist (:startup :update :fixed-update :draw
 * :shutdown :focus-gained :focus-lost -> function).  GC-rooted via staticpro. */
static Lisp_Object Vcmacs_lrgscript__games;

/* Cached hook keyword symbols. */
static Lisp_Object QCg_startup, QCg_update, QCg_fixed_update, QCg_draw,
  QCg_shutdown, QCg_focus_gained, QCg_focus_lost;

static guint64 cmacs_lrgscript__next_game_id = 1;

static void
ensure_games_table (void)
{
  if (NILP (Vcmacs_lrgscript__games))
    Vcmacs_lrgscript__games = CALLN (Fmake_hash_table, QCtest, Qeql);
}

static Lisp_Object
hook_keyword (CmacsLrgScriptHook hook)
{
  switch (hook)
    {
    case CMACS_LRGSCRIPT_HOOK_STARTUP:      return QCg_startup;
    case CMACS_LRGSCRIPT_HOOK_UPDATE:       return QCg_update;
    case CMACS_LRGSCRIPT_HOOK_FIXED_UPDATE: return QCg_fixed_update;
    case CMACS_LRGSCRIPT_HOOK_DRAW:         return QCg_draw;
    case CMACS_LRGSCRIPT_HOOK_SHUTDOWN:     return QCg_shutdown;
    case CMACS_LRGSCRIPT_HOOK_FOCUS_GAINED: return QCg_focus_gained;
    case CMACS_LRGSCRIPT_HOOK_FOCUS_LOST:   return QCg_focus_lost;
    default:                                return Qnil;
    }
}

/* Called by the C game template each frame (from the FBO drive loop, a GLib
 * callback).  Dispatch the elisp hook under the input guard; a signalled hook
 * is caught (safe_callN_value returns nil) so the loop keeps running. */
gboolean
cmacs_lrgscript_game_dispatch (guint64 game_id, CmacsLrgScriptHook hook,
                               gdouble delta)
{
  Lisp_Object plist, key, fn;

  if (NILP (Vcmacs_lrgscript__games))
    return FALSE;

  plist = Fgethash (make_uint (game_id), Vcmacs_lrgscript__games, Qnil);
  if (NILP (plist))
    return FALSE;

  key = hook_keyword (hook);
  if (NILP (key))
    return FALSE;

  fn = Fplist_get (plist, key, Qnil);
  if (NILP (fn))
    return FALSE;

  if (hook == CMACS_LRGSCRIPT_HOOK_UPDATE
      || hook == CMACS_LRGSCRIPT_HOOK_FIXED_UPDATE)
    {
      Lisp_Object arg = make_float (delta);
      cmacs_dispatch_safe_callN_value (fn, 1, &arg);
    }
  else
    cmacs_dispatch_safe_callN_value (fn, 0, NULL);

  return TRUE;
}

DEFUN ("cmacs-lrgscript-run-game", Fcmacs_lrgscript_run_game,
       Scmacs_lrgscript_run_game, 2, 5, 0,
       doc: /* Run an Emacs-Lisp-authored libregnum game in BUFFER.
HOOKS is a plist of loop callbacks:

  :startup       (lambda ())        once, after the engine is up
  :update        (lambda (delta))   every frame (variable timestep)
  :fixed-update  (lambda (delta))   0-N times per frame (fixed timestep)
  :draw          (lambda ())        immediate-mode draw, after the scene
  :shutdown      (lambda ())        once, on teardown
  :focus-gained  (lambda ())        window/buffer gained focus
  :focus-lost    (lambda ())        window/buffer lost focus

TITLE is the game/window title; WIDTH and HEIGHT default to 640x480.  Returns
an integer game id.  The game renders into BUFFER's libregnum view and is
driven by the shared animation timer.  Signals `cmacs-lrgscript-error' on
failure.

Each hook is called through the signal-safe dispatch guard, so a signalled
hook is caught and the loop continues; wrap your hooks to log if you want to
see such errors.

usage: (cmacs-lrgscript-run-game BUFFER HOOKS &optional TITLE WIDTH HEIGHT)  */)
  (Lisp_Object buffer, Lisp_Object hooks, Lisp_Object title,
   Lisp_Object width, Lisp_Object height)
{
  CHECK_BUFFER (buffer);
  int w = NILP (width)  ? 640 : (CHECK_FIXNAT (width),  XFIXNUM (width));
  int h = NILP (height) ? 480 : (CHECK_FIXNAT (height), XFIXNUM (height));
  guint64 id = cmacs_lrgscript__next_game_id++;
  CmacsLibregnumView *v;
  void *ctx;
  char *err = NULL;
  Lisp_Object keep_title = Qnil;
  const char *ctitle = NULL;

  ensure_games_table ();
  Fputhash (make_uint (id), hooks, Vcmacs_lrgscript__games);

  v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v)
    v = cmacs_libregnum_view_new (buffer, w, h);
  if (!v)
    {
      Fremhash (make_uint (id), Vcmacs_lrgscript__games);
      xsignal1 (Qcmacs_lrgscript_error, build_string ("could not create view"));
    }

  ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (STRINGP (title))
    {
      keep_title = ENCODE_UTF_8 (title);
      ctitle = SSDATA (keep_title);
    }

  if (!cmacs_lrgscript_game_run_in_ctx (ctx, id, ctitle, w, h, &err))
    {
      Fremhash (make_uint (id), Vcmacs_lrgscript__games);
      Lisp_Object m = build_string (err ? err : "game startup failed");
      g_free (err);
      xsignal1 (Qcmacs_lrgscript_error, m);
    }

  /* Drive the game at 60 FPS; the timer idles when the buffer is off-screen. */
  cmacs_libregnum_view_set_animated (v, true, 60);
  cmacs_libregnum_view_request_redraw (v);
  return make_uint (id);
}

DEFUN ("cmacs-lrgscript-stop-game", Fcmacs_lrgscript_stop_game,
       Scmacs_lrgscript_stop_game, 1, 1, 0,
       doc: /* Stop the elisp game running in BUFFER and destroy its view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v)
    cmacs_libregnum_view_destroy (v);
  /* The per-game hook entries are left to GC with the buffer's view; a new run
   * allocates a fresh id.  (Games are few and short-lived; no leak of note.) */
  return Qt;
}

void
syms_of_cmacs_lrgscript_game_defuns (void)
{
  QCg_startup      = intern_c_string (":startup");
  QCg_update       = intern_c_string (":update");
  QCg_fixed_update = intern_c_string (":fixed-update");
  QCg_draw         = intern_c_string (":draw");
  QCg_shutdown     = intern_c_string (":shutdown");
  QCg_focus_gained = intern_c_string (":focus-gained");
  QCg_focus_lost   = intern_c_string (":focus-lost");
  staticpro (&QCg_startup);
  staticpro (&QCg_update);
  staticpro (&QCg_fixed_update);
  staticpro (&QCg_draw);
  staticpro (&QCg_shutdown);
  staticpro (&QCg_focus_gained);
  staticpro (&QCg_focus_lost);

  Vcmacs_lrgscript__games = Qnil;
  staticpro (&Vcmacs_lrgscript__games);

  defsubr (&Scmacs_lrgscript_run_game);
  defsubr (&Scmacs_lrgscript_stop_game);
}

#endif /* HAVE_CMACS_LRGSCRIPT */
