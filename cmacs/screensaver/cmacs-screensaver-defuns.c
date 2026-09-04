/* cmacs-screensaver-defuns.c --- Lisp entry points for the screensaver sinks.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * These are the low-level "--" primitives; the user-facing commands, the named
 * config table, and the picker live in lisp/cmacs/cmacs-screensaver.el. */

#include <config.h>

#ifdef HAVE_CMACS_SCREENSAVER

#include "lisp.h"
#include "coding.h"
#include "buffer.h"   /* CHECK_BUFFER, for the background DEFUNs */
#include "cmacs-screensaver.h"
#ifdef HAVE_CMACS_LIBREGNUM
#include "cmacs-libregnum-render.h"
#include "cmacs-libregnum.h"
#endif

#include <glib.h>

/* Build a NULL-terminated, main()-style argv from a Lisp list of strings
 * (element 0 is the synthetic program name).  Returns a g_strv the caller must
 * g_strfreev, or NULL for nil.  Errors if a non-string element appears. */
static char **
cmacs_screensaver__argv_from_list (Lisp_Object list)
{
  GPtrArray *a;
  Lisp_Object tail;

  if (NILP (list))
    return NULL;
  CHECK_LIST (list);

  a = g_ptr_array_new ();
  g_ptr_array_add (a, g_strdup ("cmacs-screensaver"));
  for (tail = list; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object elt = XCAR (tail);
      CHECK_STRING (elt);
      g_ptr_array_add (a, g_strdup (SSDATA (ENCODE_UTF_8 (elt))));
    }
  g_ptr_array_add (a, NULL);
  return (char **) g_ptr_array_free (a, FALSE);
}

DEFUN ("cmacs-screensaver-supported-p", Fcmacs_screensaver_supported_p,
       Scmacs_screensaver_supported_p, 0, 0, 0,
       doc: /* Return non-nil if screensaver wallpaper/lock support is built in.
This requires both --with-cmacs-libregnum and --with-cmacs-gowl.  */)
  (void)
{
#ifdef HAVE_CMACS_GOWL
  return Qt;
#else
  return Qnil;
#endif
}

DEFUN ("cmacs-screensaver--start-wallpaper", Fcmacs_screensaver__start_wallpaper,
       Scmacs_screensaver__start_wallpaper, 1, 4, 0,
       doc: /* Start the animated wallpaper from screensaver module SO-PATH.
ARGV is a list of strings passed verbatim to the module (its CLI flags).
FPS bounds the shared frame pump (default 30).  When PAUSE-COVERED is
non-nil a monitor fully hidden by a fullscreen window is not rendered.
Signals an error on failure.  */)
  (Lisp_Object so_path, Lisp_Object argv, Lisp_Object fps,
   Lisp_Object pause_covered)
{
  CHECK_STRING (so_path);
  Lisp_Object enc = ENCODE_FILE (so_path);
  char **cargv = cmacs_screensaver__argv_from_list (argv);
  int ifps = FIXNUMP (fps) ? (int) XFIXNUM (fps) : 30;
  char *err = cmacs_screensaver_start (CMACS_SCREENSAVER_WALLPAPER,
                                       SSDATA (enc),
                                       (const char *const *) cargv,
                                       ifps, !NILP (pause_covered));
  g_strfreev (cargv);
  if (err != NULL)
    {
      Lisp_Object msg = build_string (err);
      g_free (err);
      error ("cmacs-screensaver: %s", SSDATA (msg));
    }
  return Qt;
}

/* ── Screensaver as a libregnum scene background ────────────────────
 *
 * The coupling lives HERE, in the optional subsystem, rather than in
 * libregnum: libregnum takes a generic frame-source function pointer
 * and knows nothing about screensavers, so it still builds and links
 * with --with-cmacs-screensaver off.  This file is the one place that
 * sees both. */

#ifdef HAVE_CMACS_LIBREGNUM

/* Adapter matching CmacsLibregnumFrameSource. */
static int
cmacs_screensaver__frame_source (gpointer user, const void **px,
                                 int *w, int *h, unsigned long long *gen)
{
  (void) user;
  return cmacs_screensaver_peek_frame (px, w, h, gen);
}

DEFUN ("cmacs-screensaver--attach-background",
       Fcmacs_screensaver__attach_background,
       Scmacs_screensaver__attach_background, 4, 6, 0,
       doc: /* Render screensaver SO-PATH behind BUFFER's libregnum scene.

WIDTH and HEIGHT are the frame size to render, normally the viewport's.
ARGV is a list of strings passed verbatim to the module (its CLI flags);
FPS bounds the shared frame pump (default 30).

The screensaver runs in the same out-of-process renderer the animated
wallpaper uses, so none of its GL ever runs on Emacs's thread, and it
needs no gowl -- this works in a plain pgtk Emacs.  Signals an error if
the module will not load.  */)
  (Lisp_Object buffer, Lisp_Object so_path, Lisp_Object width,
   Lisp_Object height, Lisp_Object argv, Lisp_Object fps)
{
  CmacsLibregnumRenderCtx *ctx;
  CmacsLibregnumView *v;
  char **cargv;
  char *err;
  int w, h, ifps;

  CHECK_BUFFER (buffer);
  CHECK_STRING (so_path);
  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);

  v = cmacs_libregnum_view_for_buffer (buffer);
  if (v == NULL)
    error ("cmacs-screensaver: no libregnum view attached to that buffer");
  ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (ctx == NULL)
    error ("cmacs-screensaver: that view has no render context");

  w = (int) XFIXNAT (width);
  h = (int) XFIXNAT (height);
  ifps = FIXNUMP (fps) ? (int) XFIXNUM (fps) : 30;

  {
    Lisp_Object enc = ENCODE_FILE (so_path);
    cargv = cmacs_screensaver__argv_from_list (argv);
    err = cmacs_screensaver_start_texture (SSDATA (enc),
                                           (const char *const *) cargv,
                                           ifps, w, h);
    g_strfreev (cargv);
  }
  if (err != NULL)
    {
      Lisp_Object msg = build_string (err);
      g_free (err);
      error ("cmacs-screensaver: %s", SSDATA (msg));
    }

  /* Register the source BEFORE selecting the kind: set_background
     refuses SOURCE with nothing to pull from, which is what keeps a
     mis-ordered caller from getting a permanently blank viewport. */
  cmacs_libregnum_render_ctx_set_background_source
    (ctx, cmacs_screensaver__frame_source, NULL, NULL);
  cmacs_libregnum_render_ctx_set_background
    (ctx, CMACS_LIBREGNUM_BG_SOURCE, 0, 0, NULL);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-screensaver--detach-background",
       Fcmacs_screensaver__detach_background,
       Scmacs_screensaver__detach_background, 1, 1, 0,
       doc: /* Stop the screensaver background in BUFFER.
The viewport falls back to its flat clear colour; the caller is expected
to set whatever background it wants next.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;

  CHECK_BUFFER (buffer);
  cmacs_screensaver_stop (CMACS_SCREENSAVER_TEXTURE);

  v = cmacs_libregnum_view_for_buffer (buffer);
  if (v != NULL)
    {
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (ctx != NULL)
        {
          cmacs_libregnum_render_ctx_set_background_source (ctx, NULL,
                                                            NULL, NULL);
          cmacs_libregnum_render_ctx_set_background
            (ctx, CMACS_LIBREGNUM_BG_NONE, 0, 0, NULL);
        }
      cmacs_libregnum_view_request_redraw (v);
    }
  return Qt;
}

DEFUN ("cmacs-screensaver--background-resize",
       Fcmacs_screensaver__background_resize,
       Scmacs_screensaver__background_resize, 2, 2, 0,
       doc: /* Re-render the screensaver background at WIDTH x HEIGHT.
A no-op when it is not running or the size is unchanged.  */)
  (Lisp_Object width, Lisp_Object height)
{
  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  cmacs_screensaver_texture_resize ((int) XFIXNAT (width),
                                    (int) XFIXNAT (height));
  return Qt;
}

#endif /* HAVE_CMACS_LIBREGNUM */

DEFUN ("cmacs-screensaver--stop-wallpaper", Fcmacs_screensaver__stop_wallpaper,
       Scmacs_screensaver__stop_wallpaper, 0, 0, 0,
       doc: /* Stop the animated wallpaper, restoring the static wallpaper.  */)
  (void)
{
  cmacs_screensaver_stop (CMACS_SCREENSAVER_WALLPAPER);
  return Qt;
}

DEFUN ("cmacs-screensaver--start-lock-bg", Fcmacs_screensaver__start_lock_bg,
       Scmacs_screensaver__start_lock_bg, 1, 3, 0,
       doc: /* Start the animated lock-screen background from module SO-PATH.
ARGV is a list of strings passed verbatim to the module.  FPS bounds the
frame pump (default 30).  Call this BEFORE engaging the lock so the
password surface renders transparently over the animation.  Signals an
error on failure.  */)
  (Lisp_Object so_path, Lisp_Object argv, Lisp_Object fps)
{
  CHECK_STRING (so_path);
  Lisp_Object enc = ENCODE_FILE (so_path);
  char **cargv = cmacs_screensaver__argv_from_list (argv);
  int ifps = FIXNUMP (fps) ? (int) XFIXNUM (fps) : 30;
  char *err = cmacs_screensaver_start (CMACS_SCREENSAVER_LOCK,
                                       SSDATA (enc),
                                       (const char *const *) cargv,
                                       ifps, 0);
  g_strfreev (cargv);
  if (err != NULL)
    {
      Lisp_Object msg = build_string (err);
      g_free (err);
      error ("cmacs-screensaver: %s", SSDATA (msg));
    }
  return Qt;
}

DEFUN ("cmacs-screensaver--stop-lock-bg", Fcmacs_screensaver__stop_lock_bg,
       Scmacs_screensaver__stop_lock_bg, 0, 0, 0,
       doc: /* Stop the animated lock-screen background.  */)
  (void)
{
  cmacs_screensaver_stop (CMACS_SCREENSAVER_LOCK);
  return Qt;
}

DEFUN ("cmacs-screensaver--wallpaper-active-p",
       Fcmacs_screensaver__wallpaper_active_p,
       Scmacs_screensaver__wallpaper_active_p, 0, 0, 0,
       doc: /* Return non-nil if an animated wallpaper session is running.  */)
  (void)
{
  return cmacs_screensaver_active (CMACS_SCREENSAVER_WALLPAPER) ? Qt : Qnil;
}

DEFUN ("cmacs-screensaver--installed-module-dir",
       Fcmacs_screensaver__installed_module_dir,
       Scmacs_screensaver__installed_module_dir, 0, 0, 0,
       doc: /* Return the compile-time install dir for screensaver `.so' modules.
This is where `make install' places them; the Elisp module resolver uses
it as the fallback after $CMACS_SCREENSAVER_MODULE_DIR.  */)
  (void)
{
#ifdef CMACS_SCREENSAVER_MODULEDIR
  return build_string (CMACS_SCREENSAVER_MODULEDIR);
#else
  return Qnil;
#endif
}

DEFUN ("cmacs-screensaver--status", Fcmacs_screensaver__status,
       Scmacs_screensaver__status, 0, 0, 0,
       doc: /* Return a plist describing the out-of-process renderer's state.
Keys: :running :pid :fps :paused :gave-up :targets :wallpaper :lock
:last-error.  */)
  (void)
{
  CmacsScreensaverStatus st;
  Lisp_Object args[18];
  int i = 0;

  cmacs_screensaver_get_status (&st);
  args[i++] = intern (":running");    args[i++] = st.running ? Qt : Qnil;
  args[i++] = intern (":pid");        args[i++] = make_fixnum (st.pid);
  args[i++] = intern (":fps");        args[i++] = make_fixnum (st.fps);
  args[i++] = intern (":paused");     args[i++] = st.paused ? Qt : Qnil;
  args[i++] = intern (":gave-up");    args[i++] = st.gave_up ? Qt : Qnil;
  args[i++] = intern (":targets");    args[i++] = make_fixnum (st.n_targets);
  args[i++] = intern (":wallpaper");  args[i++] = st.wallpaper_active ? Qt : Qnil;
  args[i++] = intern (":lock");       args[i++] = st.lock_active ? Qt : Qnil;
  args[i++] = intern (":last-error");
  args[i++] = st.last_error ? build_string (st.last_error) : Qnil;
  return Flist (i, args);
}

DEFUN ("cmacs-screensaver--restart", Fcmacs_screensaver__restart,
       Scmacs_screensaver__restart, 0, 0, 0,
       doc: /* Kill and respawn the render child, re-applying active sessions.  */)
  (void)
{
  cmacs_screensaver_restart ();
  return Qt;
}

DEFUN ("cmacs-screensaver--pause", Fcmacs_screensaver__pause,
       Scmacs_screensaver__pause, 0, 0, 0,
       doc: /* Pause rendering (the child stops drawing; the GPU goes idle).  */)
  (void)
{
  cmacs_screensaver_set_paused (1);
  return Qt;
}

DEFUN ("cmacs-screensaver--resume", Fcmacs_screensaver__resume,
       Scmacs_screensaver__resume, 0, 0, 0,
       doc: /* Resume rendering after `cmacs-screensaver--pause'.  */)
  (void)
{
  cmacs_screensaver_set_paused (0);
  return Qt;
}

DEFUN ("cmacs-screensaver--set-fps", Fcmacs_screensaver__set_fps,
       Scmacs_screensaver__set_fps, 1, 1, 0,
       doc: /* Set the target frame rate FPS (1..240) for the child and pump.  */)
  (Lisp_Object fps)
{
  CHECK_FIXNUM (fps);
  cmacs_screensaver_set_fps ((int) XFIXNUM (fps));
  return Qt;
}

DEFUN ("cmacs-screensaver--set-start-timeout", Fcmacs_screensaver__set_start_timeout,
       Scmacs_screensaver__set_start_timeout, 1, 1, 0,
       doc: /* Set the synchronous start-error wait to MS milliseconds.  */)
  (Lisp_Object ms)
{
  CHECK_FIXNUM (ms);
  cmacs_screensaver_set_start_timeout_ms ((int) XFIXNUM (ms));
  return Qt;
}

void
syms_of_cmacs_screensaver_defuns (void)
{
  defsubr (&Scmacs_screensaver_supported_p);
  defsubr (&Scmacs_screensaver__start_wallpaper);
  defsubr (&Scmacs_screensaver__stop_wallpaper);
#ifdef HAVE_CMACS_LIBREGNUM
  defsubr (&Scmacs_screensaver__attach_background);
  defsubr (&Scmacs_screensaver__detach_background);
  defsubr (&Scmacs_screensaver__background_resize);
#endif
  defsubr (&Scmacs_screensaver__start_lock_bg);
  defsubr (&Scmacs_screensaver__stop_lock_bg);
  defsubr (&Scmacs_screensaver__wallpaper_active_p);
  defsubr (&Scmacs_screensaver__installed_module_dir);
  defsubr (&Scmacs_screensaver__status);
  defsubr (&Scmacs_screensaver__restart);
  defsubr (&Scmacs_screensaver__pause);
  defsubr (&Scmacs_screensaver__resume);
  defsubr (&Scmacs_screensaver__set_fps);
  defsubr (&Scmacs_screensaver__set_start_timeout);
}

#endif /* HAVE_CMACS_SCREENSAVER */
