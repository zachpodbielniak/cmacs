/* cmacs-vidstudio-defuns.c --- Video-editor Lisp primitives.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DEFUN surface for the Reel-based video editor.  Projects are held in a small
 * C registry and referenced from Lisp by integer handle (GC-safe).  Includes
 * lisp.h and the plain-C bridge header ONLY (never <libregnum.h>). */

#include <config.h>

#ifdef HAVE_CMACS_VIDSTUDIO

#include "lisp.h"
#include "buffer.h"             /* CHECK_BUFFER for viewport-render */
#include "cmacs-vidstudio-proj.h"
#ifdef HAVE_CMACS_LIBREGNUM
/* Firewall-safe (raylib-free, opaque-ctx) headers for the live viewport. */
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#endif

/* Qcmacs_vidstudio_error is DEFSYM'd below; make-docfile generates its global
   slot, so it must NOT be a file-local variable. */

static GPtrArray *vidstudio_registry;  /* handle == index; NULL == freed */

static EMACS_INT
vs_register (CmacsVidProject *p)
{
  guint i;

  if (vidstudio_registry == NULL)
    vidstudio_registry = g_ptr_array_new ();
  for (i = 0; i < vidstudio_registry->len; i++)
    if (g_ptr_array_index (vidstudio_registry, i) == NULL)
      {
        vidstudio_registry->pdata[i] = p;
        return (EMACS_INT) i;
      }
  g_ptr_array_add (vidstudio_registry, p);
  return (EMACS_INT) (vidstudio_registry->len - 1);
}

static CmacsVidProject *
vs_lookup (Lisp_Object handle)
{
  EMACS_INT h;
  CmacsVidProject *p;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (vidstudio_registry == NULL || h < 0
      || h >= (EMACS_INT) vidstudio_registry->len)
    xsignal2 (Qcmacs_vidstudio_error,
              build_string ("unknown or closed cmacs-vidstudio handle"),
              handle);
  p = g_ptr_array_index (vidstudio_registry, h);
  if (p == NULL)
    xsignal2 (Qcmacs_vidstudio_error,
              build_string ("unknown or closed cmacs-vidstudio handle"),
              handle);
  return p;
}

static guint8
vs_clamp8 (Lisp_Object v)
{
  EMACS_INT x = INTEGERP (v) ? XFIXNUM (v) : 0;
  return (guint8) (x < 0 ? 0 : (x > 255 ? 255 : x));
}

static int
vs_int (Lisp_Object v, int dflt)
{
  return INTEGERP (v) ? (int) XFIXNUM (v) : dflt;
}

/* NUMBERP -> double; nil/other -> DFLT (used for optional seconds args). */
static double
vs_dbl (Lisp_Object v, double dflt)
{
  return NUMBERP (v) ? XFLOATINT (v) : dflt;
}

DEFUN ("cmacs-vidstudio-supported-p", Fcmacs_vidstudio_supported_p,
       Scmacs_vidstudio_supported_p, 0, 0, 0,
       doc: /* Return non-nil if cmacs was built with --with-cmacs-vidstudio.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-vidstudio-new", Fcmacs_vidstudio_new, Scmacs_vidstudio_new,
       3, 3, 0,
       doc: /* Create a WIDTH x HEIGHT project at FPS and return its handle.  */)
  (Lisp_Object width, Lisp_Object height, Lisp_Object fps)
{
  CmacsVidProject *p;
  double f;

  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);
  f = FLOATP (fps) ? XFLOAT_DATA (fps)
                   : (INTEGERP (fps) ? (double) XFIXNUM (fps) : 30.0);
  p = cmacs_vidstudio_proj_new ((int) XFIXNUM (width), (int) XFIXNUM (height),
                                f);
  if (p == NULL)
    xsignal1 (Qcmacs_vidstudio_error,
              build_string ("invalid project parameters"));
  return make_fixnum (vs_register (p));
}

DEFUN ("cmacs-vidstudio-free", Fcmacs_vidstudio_free, Scmacs_vidstudio_free,
       1, 1, 0, doc: /* Free the project referenced by HANDLE.  */)
  (Lisp_Object handle)
{
  EMACS_INT h;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (vidstudio_registry != NULL && h >= 0
      && h < (EMACS_INT) vidstudio_registry->len)
    {
      CmacsVidProject *p = g_ptr_array_index (vidstudio_registry, h);
      if (p != NULL)
        {
          cmacs_vidstudio_proj_free (p);
          vidstudio_registry->pdata[h] = NULL;
        }
    }
  return Qnil;
}

DEFUN ("cmacs-vidstudio-width", Fcmacs_vidstudio_width, Scmacs_vidstudio_width,
       1, 1, 0, doc: /* Project width.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_vidstudio_proj_width (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-height", Fcmacs_vidstudio_height,
       Scmacs_vidstudio_height, 1, 1, 0, doc: /* Project height.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_vidstudio_proj_height (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-fps", Fcmacs_vidstudio_fps, Scmacs_vidstudio_fps,
       1, 1, 0, doc: /* Project frame rate.  */)
  (Lisp_Object handle)
{
  return make_float (cmacs_vidstudio_proj_fps (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-total-frames", Fcmacs_vidstudio_total_frames,
       Scmacs_vidstudio_total_frames, 1, 1, 0,
       doc: /* Total project length in frames.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_vidstudio_proj_total_frames (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-add-track", Fcmacs_vidstudio_add_track,
       Scmacs_vidstudio_add_track, 1, 1, 0,
       doc: /* Add a track (z-order layer); return its index.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_vidstudio_proj_add_track (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-n-tracks", Fcmacs_vidstudio_n_tracks,
       Scmacs_vidstudio_n_tracks, 1, 1, 0, doc: /* Number of tracks.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_vidstudio_proj_n_tracks (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-track-clip-count", Fcmacs_vidstudio_track_clip_count,
       Scmacs_vidstudio_track_clip_count, 2, 2, 0,
       doc: /* Number of clips on TRACK.  */)
  (Lisp_Object handle, Lisp_Object track)
{
  CHECK_FIXNUM (track);
  return make_fixnum (cmacs_vidstudio_proj_track_clip_count (
                          vs_lookup (handle), (guint) XFIXNUM (track)));
}

DEFUN ("cmacs-vidstudio-track-total-frames", Fcmacs_vidstudio_track_total_frames,
       Scmacs_vidstudio_track_total_frames, 2, 2, 0,
       doc: /* Length of TRACK in frames.  */)
  (Lisp_Object handle, Lisp_Object track)
{
  CHECK_FIXNUM (track);
  return make_fixnum (cmacs_vidstudio_proj_track_total_frames (
                          vs_lookup (handle), (guint) XFIXNUM (track)));
}

DEFUN ("cmacs-vidstudio-add-solid-clip", Fcmacs_vidstudio_add_solid_clip,
       Scmacs_vidstudio_add_solid_clip, 7, 7, 0,
       doc: /* Append a solid R G B A clip of DURATION frames to TRACK.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object duration, Lisp_Object r,
   Lisp_Object g, Lisp_Object b, Lisp_Object a)
{
  CHECK_FIXNUM (track);
  return make_fixnum (cmacs_vidstudio_proj_add_solid_clip (
                          vs_lookup (handle), (guint) XFIXNUM (track),
                          vs_int (duration, 0), vs_clamp8 (r), vs_clamp8 (g),
                          vs_clamp8 (b), vs_clamp8 (a)));
}

DEFUN ("cmacs-vidstudio-add-rich-text", Fcmacs_vidstudio_add_rich_text,
       Scmacs_vidstudio_add_rich_text, 4, 6, 0,
       doc: /* Append an animated rich-text clip from BBCODE markup on TRACK for
DURATION frames.  Markup supports [b]/[i]/[color=..]/[size=..] and the animated
[wave]/[rainbow]/[typewriter]/[shake] effects.  Optional FONT-SIZE and
COLOR = (R G B A).  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object bbcode,
   Lisp_Object duration, Lisp_Object font_size, Lisp_Object color)
{
  CHECK_FIXNUM (track);
  CHECK_STRING (bbcode);
  return make_fixnum (cmacs_vidstudio_proj_add_rich_text_clip
    (vs_lookup (handle), (guint) XFIXNUM (track), SSDATA (bbcode),
     vs_int (duration, 0), vs_int (font_size, 0),
     CONSP (color) ? vs_clamp8 (Fnth (make_fixnum (0), color)) : 255,
     CONSP (color) ? vs_clamp8 (Fnth (make_fixnum (1), color)) : 255,
     CONSP (color) ? vs_clamp8 (Fnth (make_fixnum (2), color)) : 255,
     CONSP (color) ? vs_clamp8 (Fnth (make_fixnum (3), color)) : 255));
}

DEFUN ("cmacs-vidstudio-add-loop-clip", Fcmacs_vidstudio_add_loop_clip,
       Scmacs_vidstudio_add_loop_clip, 4, 5, 0,
       doc: /* Loop video PATH on TRACK over DURATION frames, repeating every
LOOP-SECS seconds (nil = the whole duration).  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object path, Lisp_Object duration,
   Lisp_Object loop_secs)
{
  char *err = NULL;
  gint id;
  CHECK_FIXNUM (track);
  CHECK_STRING (path);
  id = cmacs_vidstudio_proj_add_loop_clip (vs_lookup (handle),
    (guint) XFIXNUM (track), SSDATA (path), vs_int (duration, 0),
    vs_dbl (loop_secs, 0.0), &err);
  if (id < 0)
    { Lisp_Object m = build_string (err ? err : "loop clip failed");
      g_free (err); xsignal1 (Qcmacs_vidstudio_error, m); }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-add-freeze-clip", Fcmacs_vidstudio_add_freeze_clip,
       Scmacs_vidstudio_add_freeze_clip, 4, 5, 0,
       doc: /* Freeze-frame video PATH on TRACK for DURATION frames, holding the
frame at FREEZE-SECS seconds (default 0).  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object path, Lisp_Object duration,
   Lisp_Object freeze_secs)
{
  char *err = NULL;
  gint id;
  CHECK_FIXNUM (track);
  CHECK_STRING (path);
  id = cmacs_vidstudio_proj_add_freeze_clip (vs_lookup (handle),
    (guint) XFIXNUM (track), SSDATA (path), vs_int (duration, 0),
    vs_dbl (freeze_secs, 0.0), &err);
  if (id < 0)
    { Lisp_Object m = build_string (err ? err : "freeze clip failed");
      g_free (err); xsignal1 (Qcmacs_vidstudio_error, m); }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-add-shape-rect", Fcmacs_vidstudio_add_shape_rect,
       Scmacs_vidstudio_add_shape_rect, 8, 8, 0,
       doc: /* Append a filled rect shape (X Y W H, FILL = (R G B A)) on TRACK.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object duration, Lisp_Object x,
   Lisp_Object y, Lisp_Object w, Lisp_Object h, Lisp_Object fill)
{
  CHECK_FIXNUM (track);
  return make_fixnum (cmacs_vidstudio_proj_add_shape_rect
    (vs_lookup (handle), (guint) XFIXNUM (track), vs_int (duration, 0),
     vs_int (x, 0), vs_int (y, 0), vs_int (w, 0), vs_int (h, 0),
     vs_clamp8 (Fnth (make_fixnum (0), fill)),
     vs_clamp8 (Fnth (make_fixnum (1), fill)),
     vs_clamp8 (Fnth (make_fixnum (2), fill)),
     vs_clamp8 (Fnth (make_fixnum (3), fill))));
}

DEFUN ("cmacs-vidstudio-add-shape-circle", Fcmacs_vidstudio_add_shape_circle,
       Scmacs_vidstudio_add_shape_circle, 7, 7, 0,
       doc: /* Append a filled circle (CX CY RADIUS, FILL = (R G B A)) on TRACK.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object duration, Lisp_Object cx,
   Lisp_Object cy, Lisp_Object radius, Lisp_Object fill)
{
  CHECK_FIXNUM (track);
  return make_fixnum (cmacs_vidstudio_proj_add_shape_circle
    (vs_lookup (handle), (guint) XFIXNUM (track), vs_int (duration, 0),
     vs_int (cx, 0), vs_int (cy, 0), vs_int (radius, 0),
     vs_clamp8 (Fnth (make_fixnum (0), fill)),
     vs_clamp8 (Fnth (make_fixnum (1), fill)),
     vs_clamp8 (Fnth (make_fixnum (2), fill)),
     vs_clamp8 (Fnth (make_fixnum (3), fill))));
}

DEFUN ("cmacs-vidstudio-add-caption", Fcmacs_vidstudio_add_caption,
       Scmacs_vidstudio_add_caption, 3, 5, 0,
       doc: /* Append captions from an SRT PATH (DURATION frames); optional
FONT-SIZE and COLOR = (R G B A).  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object srt, Lisp_Object duration,
   Lisp_Object font_and_color)
{
  char *err = NULL;
  gint id;
  Lisp_Object col = CONSP (font_and_color) ? XCDR (font_and_color) : Qnil;
  int fs = CONSP (font_and_color) ? vs_int (XCAR (font_and_color), 0) : 0;
  CHECK_FIXNUM (track);
  CHECK_STRING (srt);
  id = cmacs_vidstudio_proj_add_caption
    (vs_lookup (handle), (guint) XFIXNUM (track), vs_int (duration, 0),
     SSDATA (srt), fs,
     vs_clamp8 (Fnth (make_fixnum (0), col)),
     vs_clamp8 (Fnth (make_fixnum (1), col)),
     vs_clamp8 (Fnth (make_fixnum (2), col)),
     CONSP (col) ? vs_clamp8 (Fnth (make_fixnum (3), col)) : 255, &err);
  if (id < 0)
    { Lisp_Object m = build_string (err ? err : "caption load failed");
      g_free (err); xsignal1 (Qcmacs_vidstudio_error, m); }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-add-gradient-clip",
       Fcmacs_vidstudio_add_gradient_clip,
       Scmacs_vidstudio_add_gradient_clip, 5, 6, 0,
       doc: /* Append a gradient clip on TRACK from colour A to B (lists of
R G B A); optional RADIAL non-nil draws a radial gradient.  DURATION frames.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object duration,
   Lisp_Object a, Lisp_Object b, Lisp_Object radial)
{
  CHECK_FIXNUM (track);
  return make_fixnum (cmacs_vidstudio_proj_add_gradient_clip
    (vs_lookup (handle), (guint) XFIXNUM (track), vs_int (duration, 0),
     !NILP (radial),
     vs_clamp8 (Fnth (make_fixnum (0), a)), vs_clamp8 (Fnth (make_fixnum (1), a)),
     vs_clamp8 (Fnth (make_fixnum (2), a)), vs_clamp8 (Fnth (make_fixnum (3), a)),
     vs_clamp8 (Fnth (make_fixnum (0), b)), vs_clamp8 (Fnth (make_fixnum (1), b)),
     vs_clamp8 (Fnth (make_fixnum (2), b)),
     vs_clamp8 (Fnth (make_fixnum (3), b))));
}

DEFUN ("cmacs-vidstudio-add-image-clip", Fcmacs_vidstudio_add_image_clip,
       Scmacs_vidstudio_add_image_clip, 4, 4, 0,
       doc: /* Append image PATH of DURATION frames to TRACK; return clip id.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object path,
   Lisp_Object duration)
{
  char *err = NULL;
  gint id;

  CHECK_FIXNUM (track);
  CHECK_STRING (path);
  id = cmacs_vidstudio_proj_add_image_clip (vs_lookup (handle),
                                            (guint) XFIXNUM (track),
                                            SSDATA (path),
                                            vs_int (duration, 0), &err);
  if (id < 0)
    {
      Lisp_Object msg = build_string (err ? err : "could not add image");
      g_free (err);
      xsignal1 (Qcmacs_vidstudio_error, msg);
    }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-add-video-clip", Fcmacs_vidstudio_add_video_clip,
       Scmacs_vidstudio_add_video_clip, 4, 6, 0,
       doc: /* Append video PATH to TRACK; return clip id.
Optional IN-SEC and OUT-SEC are the source in/out points in seconds.  Omit
(or nil) IN-SEC for the start; omit OUT-SEC (or pass nil / a value past the
source end) to import the whole video.  The on-timeline duration is derived
from the resulting slice.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object path,
   Lisp_Object duration, Lisp_Object in_sec, Lisp_Object out_sec)
{
  char *err = NULL;
  gint id;
  double in, out;

  CHECK_FIXNUM (track);
  CHECK_STRING (path);
  /* Back-compat: the 4th arg historically was a DURATION in frames.  If IN/OUT
     are omitted but a positive DURATION is given, treat it as a from-start
     slice of that many frames; otherwise IN-SEC/OUT-SEC drive the slice
     (nil -> -1 sentinel = start / whole video). */
  in = NILP (in_sec) ? -1.0 : vs_dbl (in_sec, -1.0);
  if (!NILP (out_sec))
    out = vs_dbl (out_sec, -1.0);
  else if (NILP (in_sec) && INTEGERP (duration) && XFIXNUM (duration) > 0)
    {
      double fps = cmacs_vidstudio_proj_fps (vs_lookup (handle));
      in = (in < 0.0) ? 0.0 : in;
      out = in + (fps > 0.0 ? XFIXNUM (duration) / fps : 0.0);
    }
  else
    out = -1.0;
  id = cmacs_vidstudio_proj_add_video_clip (vs_lookup (handle),
                                            (guint) XFIXNUM (track),
                                            SSDATA (path), in, out, &err);
  if (id < 0)
    {
      Lisp_Object msg = build_string (err ? err : "could not add video");
      g_free (err);
      xsignal1 (Qcmacs_vidstudio_error, msg);
    }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-add-text-clip", Fcmacs_vidstudio_add_text_clip,
       Scmacs_vidstudio_add_text_clip, 8, 8, 0,
       doc: /* Append a TEXT clip of DURATION frames to TRACK, colour R G B A.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object text,
   Lisp_Object duration, Lisp_Object r, Lisp_Object g, Lisp_Object b,
   Lisp_Object a)
{
  CHECK_FIXNUM (track);
  CHECK_STRING (text);
  return make_fixnum (cmacs_vidstudio_proj_add_text_clip (
                          vs_lookup (handle), (guint) XFIXNUM (track),
                          SSDATA (text), vs_int (duration, 0), vs_clamp8 (r),
                          vs_clamp8 (g), vs_clamp8 (b), vs_clamp8 (a)));
}

DEFUN ("cmacs-vidstudio-set-transition", Fcmacs_vidstudio_set_transition,
       Scmacs_vidstudio_set_transition, 5, 5, 0,
       doc: /* Set CLIP-ID's leading TRANSITION-TYPE with OVERLAP frames + EASING.
TRANSITION-TYPE: -1 none, 0 fade, 1 dissolve, 2 wipe, 3 slide, 4 zoom,
5 iris, 6 flip, 7 push, 8 clock-wipe.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object type,
   Lisp_Object overlap, Lisp_Object easing)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_transition (
             vs_lookup (handle), (gint) XFIXNUM (clip_id), vs_int (type, -1),
             vs_int (overlap, 0), vs_int (easing, 0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-add-effect", Fcmacs_vidstudio_add_effect,
       Scmacs_vidstudio_add_effect, 3, 3, 0,
       doc: /* Append effect TYPE to CLIP-ID (0 blur,1 bloom,2 color-grade,
3 vignette,4 grain).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object type)
{
  CHECK_FIXNUM (clip_id);
  CHECK_FIXNUM (type);
  return cmacs_vidstudio_proj_add_effect (vs_lookup (handle),
                                          (gint) XFIXNUM (clip_id),
                                          (int) XFIXNUM (type)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-clear-effects", Fcmacs_vidstudio_clear_effects,
       Scmacs_vidstudio_clear_effects, 2, 2, 0,
       doc: /* Remove all effects from CLIP-ID.  */)
  (Lisp_Object handle, Lisp_Object clip_id)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_clear_effects (vs_lookup (handle),
                                             (gint) XFIXNUM (clip_id))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-opacity", Fcmacs_vidstudio_set_opacity,
       Scmacs_vidstudio_set_opacity, 3, 3, 0,
       doc: /* Set CLIP-ID's opacity to O (0..1).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object o)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_opacity (vs_lookup (handle),
                                           (gint) XFIXNUM (clip_id),
                                           vs_dbl (o, 1.0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-transform", Fcmacs_vidstudio_set_transform,
       Scmacs_vidstudio_set_transform, 6, 7, 0,
       doc: /* Set CLIP-ID transform: position X Y, scale SX SY, optional
rotation ROT (radians, default 0).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object x, Lisp_Object y,
   Lisp_Object sx, Lisp_Object sy, Lisp_Object rot)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_transform (vs_lookup (handle),
                                             (gint) XFIXNUM (clip_id),
                                             vs_dbl (x, 0.0), vs_dbl (y, 0.0),
                                             vs_dbl (sx, 1.0), vs_dbl (sy, 1.0),
                                             vs_dbl (rot, 0.0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-rotation", Fcmacs_vidstudio_set_rotation,
       Scmacs_vidstudio_set_rotation, 3, 3, 0,
       doc: /* Set CLIP-ID rotation to ROT radians (keeps position/scale).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object rot)
{
  /* Re-apply transform with the given rotation; position/scale default to
     identity unless previously set (v1 keeps it simple). */
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_transform (vs_lookup (handle),
                                             (gint) XFIXNUM (clip_id),
                                             0.0, 0.0, 1.0, 1.0,
                                             vs_dbl (rot, 0.0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-anchor", Fcmacs_vidstudio_set_anchor,
       Scmacs_vidstudio_set_anchor, 4, 4, 0,
       doc: /* Set CLIP-ID transform anchor to (AX AY) frame fractions.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object ax, Lisp_Object ay)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_anchor (vs_lookup (handle),
                                          (gint) XFIXNUM (clip_id),
                                          vs_dbl (ax, 0.5), vs_dbl (ay, 0.5))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-blend-mode", Fcmacs_vidstudio_set_blend_mode,
       Scmacs_vidstudio_set_blend_mode, 3, 3, 0,
       doc: /* Set CLIP-ID blend MODE (0 normal..7 color-burn).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object mode)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_blend_mode (vs_lookup (handle),
                                              (gint) XFIXNUM (clip_id),
                                              vs_int (mode, 0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-effect-param", Fcmacs_vidstudio_set_effect_param,
       Scmacs_vidstudio_set_effect_param, 4, 4, 0,
       doc: /* Set PROP of effect EFFECT-INDEX on CLIP-ID to VALUE.
PROP is the effect property name (e.g. "radius", "intensity", "brightness").  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object effect_index,
   Lisp_Object prop_value)
{
  /* PROP-VALUE is a cons (PROP . VALUE) to stay within 4 args when combined
     with the alternative (EFFECT-INDEX PROP VALUE); accept both a cons or use
     effect_index+prop separately.  Here: (handle clip-id effect-index
     (PROP . VALUE)). */
  Lisp_Object prop, value;
  CHECK_FIXNUM (clip_id);
  CHECK_FIXNUM (effect_index);
  CHECK_CONS (prop_value);
  prop = XCAR (prop_value);
  value = XCDR (prop_value);
  CHECK_STRING (prop);
  return cmacs_vidstudio_proj_set_effect_param (vs_lookup (handle),
                                                (gint) XFIXNUM (clip_id),
                                                (int) XFIXNUM (effect_index),
                                                SSDATA (prop),
                                                vs_dbl (value, 0.0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-video-fit", Fcmacs_vidstudio_set_video_fit,
       Scmacs_vidstudio_set_video_fit, 3, 3, 0,
       doc: /* Set CLIP-ID video fit: 0 fill,1 contain,2 cover,3 stretch,4 none.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object fit)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_video_fit (vs_lookup (handle),
                                             (gint) XFIXNUM (clip_id),
                                             vs_int (fit, 0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-video-rate", Fcmacs_vidstudio_set_video_rate,
       Scmacs_vidstudio_set_video_rate, 3, 3, 0,
       doc: /* Set CLIP-ID playback RATE (1.0 normal, 2.0 double speed, 0.5 slow).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object rate)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_video_rate (vs_lookup (handle),
                                              (gint) XFIXNUM (clip_id),
                                              vs_dbl (rate, 1.0)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-video-loop", Fcmacs_vidstudio_set_video_loop,
       Scmacs_vidstudio_set_video_loop, 3, 3, 0,
       doc: /* Set CLIP-ID video looping to LOOP.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object loop)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_set_video_loop (vs_lookup (handle),
                                              (gint) XFIXNUM (clip_id),
                                              !NILP (loop)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-export-quality",
       Fcmacs_vidstudio_set_export_quality,
       Scmacs_vidstudio_set_export_quality, 1, 3, 0,
       doc: /* Set the next video export's CRF and BITRATE-KBPS (nil = default).  */)
  (Lisp_Object handle, Lisp_Object crf, Lisp_Object bitrate)
{
  cmacs_vidstudio_proj_set_export_quality (vs_lookup (handle),
                                           vs_int (crf, -1),
                                           vs_int (bitrate, 0));
  return Qnil;
}

DEFUN ("cmacs-vidstudio-add-audio-file", Fcmacs_vidstudio_add_audio_file,
       Scmacs_vidstudio_add_audio_file, 2, 6, 0,
       doc: /* Add audio PATH at FROM-FRAME with VOLUME, TRIM-START/END secs.  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object from_frame,
   Lisp_Object volume, Lisp_Object trim_start, Lisp_Object trim_end)
{
  char *err = NULL;
  gint id;
  CHECK_STRING (path);
  id = cmacs_vidstudio_proj_add_audio_file (vs_lookup (handle), SSDATA (path),
                                            vs_int (from_frame, 0),
                                            vs_dbl (volume, 1.0),
                                            vs_dbl (trim_start, 0.0),
                                            vs_dbl (trim_end, 0.0), &err);
  if (id < 0)
    { Lisp_Object m = build_string (err ? err : "add audio failed");
      g_free (err); xsignal1 (Qcmacs_vidstudio_error, m); }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-add-audio-from-clip",
       Fcmacs_vidstudio_add_audio_from_clip,
       Scmacs_vidstudio_add_audio_from_clip, 2, 4, 0,
       doc: /* Extract CLIP-ID's audio and add it at FROM-FRAME with VOLUME.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object from_frame,
   Lisp_Object volume)
{
  char *err = NULL;
  gint id;
  CHECK_FIXNUM (clip_id);
  id = cmacs_vidstudio_proj_add_audio_from_clip (vs_lookup (handle),
                                                 (gint) XFIXNUM (clip_id),
                                                 vs_int (from_frame, 0),
                                                 vs_dbl (volume, 1.0), &err);
  if (id < 0)
    { Lisp_Object m = build_string (err ? err : "extract audio failed");
      g_free (err); xsignal1 (Qcmacs_vidstudio_error, m); }
  return make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-set-audio-volume", Fcmacs_vidstudio_set_audio_volume,
       Scmacs_vidstudio_set_audio_volume, 3, 3, 0,
       doc: /* Set audio clip ID's VOLUME (linear scalar).  */)
  (Lisp_Object handle, Lisp_Object id, Lisp_Object volume)
{
  CHECK_FIXNUM (id);
  return cmacs_vidstudio_proj_set_audio_volume (vs_lookup (handle),
                                                (gint) XFIXNUM (id),
                                                vs_dbl (volume, 1.0))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-set-audio-fade", Fcmacs_vidstudio_set_audio_fade,
       Scmacs_vidstudio_set_audio_fade, 3, 3, 0,
       doc: /* Set audio clip ID's FADE-IN and FADE-OUT (seconds).  */)
  (Lisp_Object handle, Lisp_Object fade_in, Lisp_Object fade_out)
{
  /* Args: (handle id (fade-in . fade-out))? keep 3 positional: id fade-in
     packs fade-out via a cons.  Simpler: (handle id fade-in) + separate.  Here
     ID is the 2nd arg; FADE-IN carries a cons (IN . OUT). */
  Lisp_Object id = fade_in, pair = fade_out;
  CHECK_FIXNUM (id);
  CHECK_CONS (pair);
  return cmacs_vidstudio_proj_set_audio_fade (vs_lookup (handle),
                                              (gint) XFIXNUM (id),
                                              vs_dbl (XCAR (pair), 0.0),
                                              vs_dbl (XCDR (pair), 0.0))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-remove-audio", Fcmacs_vidstudio_remove_audio,
       Scmacs_vidstudio_remove_audio, 2, 2, 0,
       doc: /* Remove audio clip ID.  */)
  (Lisp_Object handle, Lisp_Object id)
{
  CHECK_FIXNUM (id);
  return cmacs_vidstudio_proj_remove_audio (vs_lookup (handle),
                                            (gint) XFIXNUM (id)) ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-audio-count", Fcmacs_vidstudio_audio_count,
       Scmacs_vidstudio_audio_count, 1, 1, 0,
       doc: /* Number of audio clips on the lane.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_vidstudio_proj_audio_count (vs_lookup (handle)));
}

DEFUN ("cmacs-vidstudio-export-audio", Fcmacs_vidstudio_export_audio,
       Scmacs_vidstudio_export_audio, 2, 3, 0,
       doc: /* Export the mixed audio to PATH; FORMAT 0 WAV,1 MP3,2 AAC,3 FLAC.  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object format)
{
  char *err = NULL;
  CHECK_STRING (path);
  if (!cmacs_vidstudio_proj_export_audio (vs_lookup (handle), SSDATA (path),
                                          vs_int (format, 0), &err))
    { Lisp_Object m = build_string (err ? err : "audio export failed");
      g_free (err); xsignal1 (Qcmacs_vidstudio_error, m); }
  return Qt;
}

DEFUN ("cmacs-vidstudio-serialize", Fcmacs_vidstudio_serialize,
       Scmacs_vidstudio_serialize, 1, 1, 0,
       doc: /* Return HANDLE's project as a Lisp-readable S-expression string.  */)
  (Lisp_Object handle)
{
  char *s = cmacs_vidstudio_proj_serialize (vs_lookup (handle));
  Lisp_Object res;
  if (s == NULL)
    return Qnil;
  res = build_string (s);
  g_free (s);
  return res;
}

DEFUN ("cmacs-vidstudio-add-keyframe", Fcmacs_vidstudio_add_keyframe,
       Scmacs_vidstudio_add_keyframe, 5, 8, 0,
       doc: /* Add a keyframe on CLIP-ID: PARAM at FRAME = VALUE.
PARAM: 0 opacity, 1 x, 2 y, 3 scale, 4 rotation, 5 effect-param.  Optional
EASING (LrgEasingType int, default 0 linear), EFFECT-INDEX and PROP (for
PARAM 5).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object param,
   Lisp_Object frame, Lisp_Object value, Lisp_Object easing,
   Lisp_Object effect_index, Lisp_Object prop)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_add_keyframe
           (vs_lookup (handle), (gint) XFIXNUM (clip_id), vs_int (param, 0),
            vs_int (effect_index, 0), STRINGP (prop) ? SSDATA (prop) : NULL,
            vs_dbl (frame, 0.0), vs_dbl (value, 0.0), vs_int (easing, 0))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-clear-keyframes", Fcmacs_vidstudio_clear_keyframes,
       Scmacs_vidstudio_clear_keyframes, 2, 3, 0,
       doc: /* Clear keyframes on CLIP-ID; optional PARAM limits to one
parameter (omit / nil = all).  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object param)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_clear_keyframes (vs_lookup (handle),
                                               (gint) XFIXNUM (clip_id),
                                               NILP (param) ? -1
                                               : vs_int (param, -1))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-keyframe-count", Fcmacs_vidstudio_keyframe_count,
       Scmacs_vidstudio_keyframe_count, 2, 2, 0,
       doc: /* Number of keyframes on CLIP-ID, or -1 if unknown.  */)
  (Lisp_Object handle, Lisp_Object clip_id)
{
  CHECK_FIXNUM (clip_id);
  return make_fixnum (cmacs_vidstudio_proj_keyframe_count
                        (vs_lookup (handle), (gint) XFIXNUM (clip_id)));
}

DEFUN ("cmacs-vidstudio-export-still", Fcmacs_vidstudio_export_still,
       Scmacs_vidstudio_export_still, 3, 3, 0,
       doc: /* Render FRAME straight to PATH (PNG/JPG by extension).  */)
  (Lisp_Object handle, Lisp_Object frame, Lisp_Object path)
{
  char *err = NULL;
  CHECK_FIXNUM (frame);
  CHECK_STRING (path);
  if (!cmacs_vidstudio_proj_export_still (vs_lookup (handle),
                                          (int) XFIXNUM (frame),
                                          SSDATA (path), &err))
    {
      Lisp_Object msg = build_string (err ? err : "still export failed");
      g_free (err);
      xsignal1 (Qcmacs_vidstudio_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-vidstudio-set-clip-duration", Fcmacs_vidstudio_set_clip_duration,
       Scmacs_vidstudio_set_clip_duration, 3, 3, 0,
       doc: /* Set CLIP-ID's duration to FRAMES.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object frames)
{
  CHECK_FIXNUM (clip_id);
  CHECK_FIXNUM (frames);
  return cmacs_vidstudio_proj_set_clip_duration (vs_lookup (handle),
                                                 (gint) XFIXNUM (clip_id),
                                                 (int) XFIXNUM (frames))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-split-clip", Fcmacs_vidstudio_split_clip,
       Scmacs_vidstudio_split_clip, 3, 3, 0,
       doc: /* Split CLIP-ID at AT-FRAME; return the new tail clip id or nil.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object at_frame)
{
  gint id;

  CHECK_FIXNUM (clip_id);
  CHECK_FIXNUM (at_frame);
  id = cmacs_vidstudio_proj_split_clip (vs_lookup (handle),
                                        (gint) XFIXNUM (clip_id),
                                        (int) XFIXNUM (at_frame));
  return id < 0 ? Qnil : make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-move-clip", Fcmacs_vidstudio_move_clip,
       Scmacs_vidstudio_move_clip, 4, 4, 0,
       doc: /* Move CLIP-ID to NEW-TRACK at NEW-INDEX.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object new_track,
   Lisp_Object new_index)
{
  CHECK_FIXNUM (clip_id);
  CHECK_FIXNUM (new_track);
  CHECK_FIXNUM (new_index);
  return cmacs_vidstudio_proj_move_clip (vs_lookup (handle),
                                         (gint) XFIXNUM (clip_id),
                                         (guint) XFIXNUM (new_track),
                                         (guint) XFIXNUM (new_index))
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-remove-clip", Fcmacs_vidstudio_remove_clip,
       Scmacs_vidstudio_remove_clip, 2, 3, 0,
       doc: /* Remove CLIP-ID.  RIPPLE non-nil shifts later clips earlier,
else leaves a transparent gap.  */)
  (Lisp_Object handle, Lisp_Object clip_id, Lisp_Object ripple)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_remove_clip (vs_lookup (handle),
                                           (gint) XFIXNUM (clip_id),
                                           NILP (ripple) ? FALSE : TRUE)
             ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-clip-at", Fcmacs_vidstudio_clip_at,
       Scmacs_vidstudio_clip_at, 3, 3, 0,
       doc: /* Return the clip id at TRACK INDEX, or nil.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object index)
{
  gint id;

  CHECK_FIXNUM (track);
  CHECK_FIXNUM (index);
  id = cmacs_vidstudio_proj_clip_at (vs_lookup (handle),
                                     (guint) XFIXNUM (track),
                                     (guint) XFIXNUM (index));
  return id < 0 ? Qnil : make_fixnum (id);
}

DEFUN ("cmacs-vidstudio-clip-duration", Fcmacs_vidstudio_clip_duration,
       Scmacs_vidstudio_clip_duration, 2, 2, 0,
       doc: /* Duration of CLIP-ID in frames, or nil.  */)
  (Lisp_Object handle, Lisp_Object clip_id)
{
  gint d;

  CHECK_FIXNUM (clip_id);
  d = cmacs_vidstudio_proj_clip_duration (vs_lookup (handle),
                                          (gint) XFIXNUM (clip_id));
  return d < 0 ? Qnil : make_fixnum (d);
}

DEFUN ("cmacs-vidstudio-clip-ready-p", Fcmacs_vidstudio_clip_ready_p,
       Scmacs_vidstudio_clip_ready_p, 2, 2, 0,
       doc: /* Return t once CLIP-ID's frames are decoded and ready.
Video clips decode on a worker thread after import; until then the
preview composites a placeholder for them.  Non-video clips are always
ready.  */)
  (Lisp_Object handle, Lisp_Object clip_id)
{
  CHECK_FIXNUM (clip_id);
  return cmacs_vidstudio_proj_clip_ready (vs_lookup (handle),
                                          (gint) XFIXNUM (clip_id))
         ? Qt : Qnil;
}

DEFUN ("cmacs-vidstudio-clip-start-frame", Fcmacs_vidstudio_clip_start_frame,
       Scmacs_vidstudio_clip_start_frame, 2, 2, 0,
       doc: /* Start frame of CLIP-ID on its track, or nil.  */)
  (Lisp_Object handle, Lisp_Object clip_id)
{
  gint s;

  CHECK_FIXNUM (clip_id);
  s = cmacs_vidstudio_proj_clip_start_frame (vs_lookup (handle),
                                             (gint) XFIXNUM (clip_id));
  return s < 0 ? Qnil : make_fixnum (s);
}

DEFUN ("cmacs-vidstudio-render-png", Fcmacs_vidstudio_render_png,
       Scmacs_vidstudio_render_png, 2, 2, 0,
       doc: /* Render FRAME and return it as a unibyte PNG string.  */)
  (Lisp_Object handle, Lisp_Object frame)
{
  gsize n = 0;
  guint8 *bytes;
  Lisp_Object res;

  CHECK_FIXNUM (frame);
  bytes = cmacs_vidstudio_proj_render_png (vs_lookup (handle),
                                           (int) XFIXNUM (frame), &n);
  if (bytes == NULL || n == 0)
    {
      g_free (bytes);
      xsignal1 (Qcmacs_vidstudio_error, build_string ("frame render failed"));
    }
  res = make_unibyte_string ((const char *) bytes, (ptrdiff_t) n);
  g_free (bytes);
  return res;
}

DEFUN ("cmacs-vidstudio-viewport-render", Fcmacs_vidstudio_viewport_render,
       Scmacs_vidstudio_viewport_render, 3, 3, 0,
       doc: /* Render HANDLE's FRAME into BUFFER's live libregnum viewport.
Returns t on success, nil if the viewport is unavailable.  */)
  (Lisp_Object handle, Lisp_Object buffer, Lisp_Object frame)
{
#ifdef HAVE_CMACS_LIBREGNUM
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  void *img;

  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (frame);
  v = cmacs_libregnum_view_for_buffer (buffer);
  ctx = v ? cmacs_libregnum_view_get_render_ctx (v) : NULL;
  if (!ctx)
    return Qnil;
  img = cmacs_vidstudio_proj_canvas_image (vs_lookup (handle),
                                           (int) XFIXNUM (frame));
  if (img)
    {
      cmacs_libregnum_render_ctx_image_set_grl_image (ctx, img); /* transfer */
      cmacs_libregnum_view_request_redraw (v);
      return Qt;
    }
#else
  (void) handle; (void) buffer; (void) frame;
#endif
  return Qnil;
}

DEFUN ("cmacs-vidstudio-render-ppm", Fcmacs_vidstudio_render_ppm,
       Scmacs_vidstudio_render_ppm, 2, 3, 0,
       doc: /* Render FRAME as a binary PPM (P6) unibyte string.
Optional MAX-WIDTH downscales the frame to at most that many pixels wide
(keeping aspect) before encoding.  PPM is uncompressed, so producing and
displaying it is far faster than `cmacs-vidstudio-render-png' -- use this
for playback previews.  */)
  (Lisp_Object handle, Lisp_Object frame, Lisp_Object max_width)
{
  gsize n = 0;
  guint8 *bytes;
  Lisp_Object res;
  int mw = 0;

  CHECK_FIXNUM (frame);
  if (!NILP (max_width))
    {
      CHECK_FIXNUM (max_width);
      mw = (int) XFIXNUM (max_width);
    }
  bytes = cmacs_vidstudio_proj_render_ppm (vs_lookup (handle),
                                           (int) XFIXNUM (frame), mw, &n);
  if (bytes == NULL || n == 0)
    {
      g_free (bytes);
      xsignal1 (Qcmacs_vidstudio_error, build_string ("frame render failed"));
    }
  res = make_unibyte_string ((const char *) bytes, (ptrdiff_t) n);
  g_free (bytes);
  return res;
}

DEFUN ("cmacs-vidstudio-frame-pixel", Fcmacs_vidstudio_frame_pixel,
       Scmacs_vidstudio_frame_pixel, 4, 4, 0,
       doc: /* Return the composited pixel (R G B A) at FRAME X Y, or nil.  */)
  (Lisp_Object handle, Lisp_Object frame, Lisp_Object x, Lisp_Object y)
{
  guint8 r = 0, g = 0, b = 0, a = 0;

  CHECK_FIXNUM (frame);
  if (!cmacs_vidstudio_proj_frame_pixel (vs_lookup (handle),
                                         (int) XFIXNUM (frame), vs_int (x, -1),
                                         vs_int (y, -1), &r, &g, &b, &a))
    return Qnil;
  return list4 (make_fixnum (r), make_fixnum (g), make_fixnum (b),
                make_fixnum (a));
}

DEFUN ("cmacs-vidstudio-export-video", Fcmacs_vidstudio_export_video,
       Scmacs_vidstudio_export_video, 2, 3, 0,
       doc: /* Export to PATH with CODEC (0 h264,1 vp9,2 h265,3 prores).  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object codec)
{
  char *err = NULL;

  CHECK_STRING (path);
  if (!cmacs_vidstudio_proj_export_video (vs_lookup (handle), SSDATA (path),
                                          vs_int (codec, 0), &err))
    {
      Lisp_Object msg = build_string (err ? err : "video export failed");
      g_free (err);
      xsignal1 (Qcmacs_vidstudio_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-vidstudio-export-gif", Fcmacs_vidstudio_export_gif,
       Scmacs_vidstudio_export_gif, 2, 2, 0,
       doc: /* Export the project to PATH as an animated GIF.  */)
  (Lisp_Object handle, Lisp_Object path)
{
  char *err = NULL;

  CHECK_STRING (path);
  if (!cmacs_vidstudio_proj_export_gif (vs_lookup (handle), SSDATA (path),
                                        &err))
    {
      Lisp_Object msg = build_string (err ? err : "GIF export failed");
      g_free (err);
      xsignal1 (Qcmacs_vidstudio_error, msg);
    }
  return Qt;
}

void
syms_of_cmacs_vidstudio_defuns (void)
{
  DEFSYM (Qcmacs_vidstudio_error, "cmacs-vidstudio-error");
  Fput (Qcmacs_vidstudio_error, Qerror_conditions,
        list2 (Qcmacs_vidstudio_error, Qerror));
  Fput (Qcmacs_vidstudio_error, Qerror_message,
        build_string ("CMacs video-editor error"));

  defsubr (&Scmacs_vidstudio_supported_p);
  defsubr (&Scmacs_vidstudio_new);
  defsubr (&Scmacs_vidstudio_free);
  defsubr (&Scmacs_vidstudio_width);
  defsubr (&Scmacs_vidstudio_height);
  defsubr (&Scmacs_vidstudio_fps);
  defsubr (&Scmacs_vidstudio_total_frames);
  defsubr (&Scmacs_vidstudio_add_track);
  defsubr (&Scmacs_vidstudio_n_tracks);
  defsubr (&Scmacs_vidstudio_track_clip_count);
  defsubr (&Scmacs_vidstudio_track_total_frames);
  defsubr (&Scmacs_vidstudio_add_solid_clip);
  defsubr (&Scmacs_vidstudio_add_rich_text);
  defsubr (&Scmacs_vidstudio_add_loop_clip);
  defsubr (&Scmacs_vidstudio_add_freeze_clip);
  defsubr (&Scmacs_vidstudio_add_shape_rect);
  defsubr (&Scmacs_vidstudio_add_shape_circle);
  defsubr (&Scmacs_vidstudio_add_caption);
  defsubr (&Scmacs_vidstudio_add_gradient_clip);
  defsubr (&Scmacs_vidstudio_add_image_clip);
  defsubr (&Scmacs_vidstudio_add_video_clip);
  defsubr (&Scmacs_vidstudio_add_text_clip);
  defsubr (&Scmacs_vidstudio_set_transition);
  defsubr (&Scmacs_vidstudio_add_effect);
  defsubr (&Scmacs_vidstudio_clear_effects);
  defsubr (&Scmacs_vidstudio_set_clip_duration);
  defsubr (&Scmacs_vidstudio_split_clip);
  defsubr (&Scmacs_vidstudio_move_clip);
  defsubr (&Scmacs_vidstudio_remove_clip);
  defsubr (&Scmacs_vidstudio_clip_at);
  defsubr (&Scmacs_vidstudio_clip_duration);
  defsubr (&Scmacs_vidstudio_clip_ready_p);
  defsubr (&Scmacs_vidstudio_clip_start_frame);
  defsubr (&Scmacs_vidstudio_render_png);
  defsubr (&Scmacs_vidstudio_render_ppm);
  defsubr (&Scmacs_vidstudio_viewport_render);
  defsubr (&Scmacs_vidstudio_frame_pixel);
  defsubr (&Scmacs_vidstudio_set_opacity);
  defsubr (&Scmacs_vidstudio_set_transform);
  defsubr (&Scmacs_vidstudio_set_rotation);
  defsubr (&Scmacs_vidstudio_set_anchor);
  defsubr (&Scmacs_vidstudio_set_blend_mode);
  defsubr (&Scmacs_vidstudio_set_effect_param);
  defsubr (&Scmacs_vidstudio_set_video_fit);
  defsubr (&Scmacs_vidstudio_set_video_rate);
  defsubr (&Scmacs_vidstudio_set_video_loop);
  defsubr (&Scmacs_vidstudio_set_export_quality);
  defsubr (&Scmacs_vidstudio_export_still);
  defsubr (&Scmacs_vidstudio_serialize);
  defsubr (&Scmacs_vidstudio_add_keyframe);
  defsubr (&Scmacs_vidstudio_clear_keyframes);
  defsubr (&Scmacs_vidstudio_keyframe_count);
  defsubr (&Scmacs_vidstudio_add_audio_file);
  defsubr (&Scmacs_vidstudio_add_audio_from_clip);
  defsubr (&Scmacs_vidstudio_set_audio_volume);
  defsubr (&Scmacs_vidstudio_set_audio_fade);
  defsubr (&Scmacs_vidstudio_remove_audio);
  defsubr (&Scmacs_vidstudio_audio_count);
  defsubr (&Scmacs_vidstudio_export_audio);
  defsubr (&Scmacs_vidstudio_export_video);
  defsubr (&Scmacs_vidstudio_export_gif);
}

#endif /* HAVE_CMACS_VIDSTUDIO */
