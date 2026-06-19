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
#include "cmacs-screensaver.h"

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

void
syms_of_cmacs_screensaver_defuns (void)
{
  defsubr (&Scmacs_screensaver_supported_p);
  defsubr (&Scmacs_screensaver__start_wallpaper);
  defsubr (&Scmacs_screensaver__stop_wallpaper);
  defsubr (&Scmacs_screensaver__start_lock_bg);
  defsubr (&Scmacs_screensaver__stop_lock_bg);
  defsubr (&Scmacs_screensaver__wallpaper_active_p);
  defsubr (&Scmacs_screensaver__installed_module_dir);
}

#endif /* HAVE_CMACS_SCREENSAVER */
