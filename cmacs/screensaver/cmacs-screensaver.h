/* cmacs-screensaver.h --- libregnum screensavers as wallpaper / lock / buffer.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Renders libregnum game-module screensavers (deps/screensavers) off-screen
 * and routes the frames to one of three sinks:
 *   - WALLPAPER : pushed into gowl's BG layer (animated wallpaper),
 *   - LOCK      : pushed into gowl's session-lock layer (animated lock bg),
 *   - buffer    : handled entirely in Elisp via `cmacs-libregnum-play'.
 *
 * Only finished ARGB8888/BGRA pixels cross into gowl (see gowl-frame-sink.h);
 * gowl never links libregnum. */

#ifndef CMACS_SCREENSAVER_H
#define CMACS_SCREENSAVER_H

#include "lisp.h"

/* syms_of_cmacs_screensaver / init_cmacs_screensaver are declared in lisp.h
 * (gated by HAVE_CMACS_SCREENSAVER), matching the other cmacs subsystems. */

/* Registered by the init translation unit. */
extern void syms_of_cmacs_screensaver_defuns (void);

/* Frame-sink targets driven by the pump. */
enum cmacs_screensaver_sink
{
  CMACS_SCREENSAVER_WALLPAPER = 0,
  CMACS_SCREENSAVER_LOCK = 1
};

/* Start (or replace) the SINK with screensaver module SO_PATH, configured by
 * the NULL-terminated CLI-style ARGV (may be NULL).  FPS bounds the shared
 * frame pump; PAUSE_COVERED (wallpaper only) skips monitors fully occluded by
 * a fullscreen window.  Returns NULL on success, or a newly-allocated error
 * string (caller frees with g_free) on failure. */
extern char *cmacs_screensaver_start (int sink, const char *so_path,
                                      const char *const *argv,
                                      int fps, int pause_covered);

/* Stop the SINK: tear down its render contexts and clear its gowl frames. */
extern void cmacs_screensaver_stop (int sink);

/* TRUE if SINK currently has an active session. */
extern int cmacs_screensaver_active (int sink);

#endif /* CMACS_SCREENSAVER_H */
