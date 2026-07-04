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
#include "cmacs-vidstudio-proj.h"

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
       Scmacs_vidstudio_add_video_clip, 4, 4, 0,
       doc: /* Append video PATH of DURATION frames to TRACK; return clip id.  */)
  (Lisp_Object handle, Lisp_Object track, Lisp_Object path,
   Lisp_Object duration)
{
  char *err = NULL;
  gint id;

  CHECK_FIXNUM (track);
  CHECK_STRING (path);
  id = cmacs_vidstudio_proj_add_video_clip (vs_lookup (handle),
                                            (guint) XFIXNUM (track),
                                            SSDATA (path),
                                            vs_int (duration, 0), &err);
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
  defsubr (&Scmacs_vidstudio_frame_pixel);
  defsubr (&Scmacs_vidstudio_export_video);
  defsubr (&Scmacs_vidstudio_export_gif);
}

#endif /* HAVE_CMACS_VIDSTUDIO */
