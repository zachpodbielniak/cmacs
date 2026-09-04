/* cmacs-screensaver.h --- libregnum screensavers as wallpaper / lock / buffer.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Renders libregnum game-module screensavers (deps/screensavers) off-screen
 * and routes the frames to one of these sinks:
 *   - WALLPAPER : pushed into gowl's BG layer (animated wallpaper),
 *   - LOCK      : pushed into gowl's session-lock layer (animated lock bg),
 *   - TEXTURE   : handed to an in-process consumer, which is how a
 *                 screensaver ends up behind a libregnum scene,
 *   - buffer    : handled entirely in Elisp via `cmacs-libregnum-play'.
 *
 * Only finished ARGB8888/BGRA pixels cross into gowl (see gowl-frame-sink.h);
 * gowl never links libregnum.  TEXTURE needs no gowl at all, so a screensaver
 * background works in a plain pgtk Emacs.
 *
 * This header is included from lisp.h-side translation units, so it speaks
 * plain C types rather than glib ones. */

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
  CMACS_SCREENSAVER_LOCK = 1,
  /* Frames are handed to an in-process consumer instead of the
   * compositor: the caller says how big, reads the newest complete
   * frame with cmacs_screensaver_peek_frame, and does what it likes
   * with the pixels.  Unlike the other two this needs no gowl and no
   * monitor geometry, which is what lets a screensaver render behind a
   * libregnum scene in a plain pgtk Emacs. */
  CMACS_SCREENSAVER_TEXTURE = 2
};

#define CMACS_SCREENSAVER_N_SINKS 3

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

/* Start (or reconfigure) the TEXTURE sink at W x H.
 *
 * Separate from cmacs_screensaver_start because the two disagree about
 * where size comes from: wallpaper and lock take it from the monitors
 * gowl reports, and this takes it from the caller.  Returns NULL on
 * success or a newly-allocated error string. */
extern char *cmacs_screensaver_start_texture (const char *so_path,
                                              const char *const *argv,
                                              int fps, int w, int h);

/* Resize the TEXTURE sink.  A no-op when it is not running or the size
 * is unchanged; otherwise the child re-creates its buffer and
 * re-announces, and peek returns FALSE until the first new frame. */
extern void cmacs_screensaver_texture_resize (int w, int h);

/* Borrow the TEXTURE sink's newest complete frame.
 *
 * PIXELS is ARGB8888, W*4 bytes per row, valid only until the next main
 * loop iteration -- copy or upload it now.  GEN identifies the frame so
 * a consumer can skip re-uploading one it already has.
 *
 * Returns FALSE when the sink is idle, no frame has arrived yet, or the
 * writer was mid-frame; all three mean "nothing new", never an error. */
extern int cmacs_screensaver_peek_frame (const void **pixels,
                                         int *w, int *h,
                                         unsigned long long *generation);

/* TRUE if SINK currently has an active session. */
extern int cmacs_screensaver_active (int sink);

/* Pause/resume rendering in the child (covered + paused targets burn no GPU). */
extern void cmacs_screensaver_set_paused (int paused);

/* Change the target frame rate (1..240) for both the child and the pump. */
extern void cmacs_screensaver_set_fps (int fps);

/* Kill and respawn the render child, re-applying the active sessions. */
extern void cmacs_screensaver_restart (void);

/* Bound for the synchronous wait that surfaces a module's load error on start. */
extern void cmacs_screensaver_set_start_timeout_ms (int ms);

/* A snapshot of the subsystem state for the `status' command. */
typedef struct
{
  int          running;          /* render child process alive */
  long         pid;              /* child pid, or 0 */
  int          fps;
  int          paused;
  int          gave_up;          /* crash-loop give-up latched */
  int          n_targets;        /* mapped (announced) frame buffers */
  int          wallpaper_active;
  int          lock_active;
  const char  *last_error;       /* borrowed; valid until the next call */
} CmacsScreensaverStatus;

extern void cmacs_screensaver_get_status (CmacsScreensaverStatus *out);

#endif /* CMACS_SCREENSAVER_H */
