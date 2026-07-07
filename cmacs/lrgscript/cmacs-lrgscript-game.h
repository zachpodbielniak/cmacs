/* cmacs-lrgscript-game.h --- elisp-authored libregnum games.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The game-authoring layer: an LrgGameTemplate subclass (CmacsLrgScriptGame,
 * in cmacs-lrgscript-game.c) whose loop vfuncs dispatch to a set of Emacs Lisp
 * hooks, so a complete game can be written in `.el' and run in a
 * cmacs-libregnum buffer.  Hooks are keyed by an opaque game id and dispatched
 * lisp-side (cmacs-lrgscript-game-defuns.c) under the input guard with
 * per-frame error isolation.
 *
 * glib-only (no lisp.h, no <libregnum.h>) so it bridges the two halves. */

#ifndef CMACS_LRGSCRIPT_GAME_H
#define CMACS_LRGSCRIPT_GAME_H

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include <glib.h>

G_BEGIN_DECLS

/* The loop hooks a game may provide.  STARTUP/SHUTDOWN/DRAW/FOCUS_* take no
 * delta; UPDATE/FIXED_UPDATE receive the frame delta (seconds). */
typedef enum
{
  CMACS_LRGSCRIPT_HOOK_STARTUP,
  CMACS_LRGSCRIPT_HOOK_UPDATE,
  CMACS_LRGSCRIPT_HOOK_FIXED_UPDATE,
  CMACS_LRGSCRIPT_HOOK_DRAW,
  CMACS_LRGSCRIPT_HOOK_SHUTDOWN,
  CMACS_LRGSCRIPT_HOOK_FOCUS_GAINED,
  CMACS_LRGSCRIPT_HOOK_FOCUS_LOST
} CmacsLrgScriptHook;

/* Dispatch a game hook to its elisp callback (lisp side,
 * cmacs-lrgscript-game-defuns.c).  Runs under the waiting_for_input guard and
 * catches signals so a buggy hook never aborts the frame loop.  Returns TRUE
 * if a hook was registered and ran. */
gboolean cmacs_lrgscript_game_dispatch (guint64            game_id,
                                        CmacsLrgScriptHook hook,
                                        gdouble            delta);

/* Build a CmacsLrgScriptGame bound to GAME_ID and host it in the render ctx
 * RENDER_CTX (opaque; a CmacsLibregnumRenderCtx*).  Implemented libregnum-side
 * in cmacs-lrgscript-game.c.  On failure returns FALSE and sets *ERR (g_free). */
gboolean cmacs_lrgscript_game_run_in_ctx (gpointer     render_ctx,
                                          guint64      game_id,
                                          const gchar *title,
                                          gint         width,
                                          gint         height,
                                          gchar      **err);

G_END_DECLS

#endif /* HAVE_CMACS_LRGSCRIPT */
#endif /* CMACS_LRGSCRIPT_GAME_H */
