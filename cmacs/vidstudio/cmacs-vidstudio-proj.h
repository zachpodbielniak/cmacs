/* cmacs-vidstudio-proj.h --- C-only video-project bridge API.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Plain-C wrapper around a libregnum Reel-based editor project (tracks of
 * clip segments joined by transitions, rendered with LrgReelRenderer and
 * exported via the ffmpeg-backed reel exporters).  Pulls in NO libregnum /
 * raylib types, so the DEFUN TU (which includes lisp.h and its `Color'
 * typedef) can include it freely -- the implementation is the only vidstudio
 * TU that includes <libregnum.h>. */

#ifndef CMACS_VIDSTUDIO_PROJ_H
#define CMACS_VIDSTUDIO_PROJ_H

#include <config.h>

#ifdef HAVE_CMACS_VIDSTUDIO

#include <glib.h>

typedef struct CmacsVidProject CmacsVidProject;

/* Transition kinds (cmacs_vidstudio_proj_set_transition `type'). */
enum
{
  CMACS_VID_TRANS_NONE = -1,
  CMACS_VID_TRANS_FADE = 0,
  CMACS_VID_TRANS_DISSOLVE,
  CMACS_VID_TRANS_WIPE,
  CMACS_VID_TRANS_SLIDE,
  CMACS_VID_TRANS_ZOOM,
  CMACS_VID_TRANS_IRIS,
  CMACS_VID_TRANS_FLIP,
  CMACS_VID_TRANS_PUSH,
  CMACS_VID_TRANS_CLOCK_WIPE
};

/* Effect kinds (cmacs_vidstudio_proj_add_effect `type'). */
enum
{
  CMACS_VID_FX_BLUR = 0,
  CMACS_VID_FX_BLOOM,
  CMACS_VID_FX_COLOR_GRADE,
  CMACS_VID_FX_VIGNETTE,
  CMACS_VID_FX_GRAIN
};

/* Lifecycle. */
extern CmacsVidProject *cmacs_vidstudio_proj_new (int w, int h, double fps);
extern void cmacs_vidstudio_proj_free (CmacsVidProject *p);

extern int    cmacs_vidstudio_proj_width  (CmacsVidProject *p);
extern int    cmacs_vidstudio_proj_height (CmacsVidProject *p);
extern double cmacs_vidstudio_proj_fps    (CmacsVidProject *p);
extern int    cmacs_vidstudio_proj_total_frames (CmacsVidProject *p);

/* Tracks (z-order: 0 == bottom). */
extern guint cmacs_vidstudio_proj_add_track (CmacsVidProject *p);
extern guint cmacs_vidstudio_proj_n_tracks  (CmacsVidProject *p);
extern guint cmacs_vidstudio_proj_track_clip_count (CmacsVidProject *p,
                                                    guint track);
extern gint  cmacs_vidstudio_proj_track_total_frames (CmacsVidProject *p,
                                                      guint track);

/* Clip insertion -- each returns a stable clip id (>= 0), or -1 on error.
 * DURATION is in frames. */
extern gint cmacs_vidstudio_proj_add_solid_clip (CmacsVidProject *p,
                                                 guint track, int duration,
                                                 guint8 r, guint8 g, guint8 b,
                                                 guint8 a);
extern gint cmacs_vidstudio_proj_add_image_clip (CmacsVidProject *p,
                                                 guint track, const char *path,
                                                 int duration,
                                                 char **error_msg);
/* Add a video clip.  IN_SEC/OUT_SEC are the source in/out points in seconds:
   IN_SEC < 0 means start (0); OUT_SEC <= 0 (or past the source) means the whole
   video to its end.  The on-timeline duration is derived from the slice. */
extern gint cmacs_vidstudio_proj_add_video_clip (CmacsVidProject *p,
                                                 guint track, const char *path,
                                                 double in_sec, double out_sec,
                                                 char **error_msg);
extern gint cmacs_vidstudio_proj_add_text_clip (CmacsVidProject *p,
                                                guint track, const char *text,
                                                int duration,
                                                guint8 r, guint8 g, guint8 b,
                                                guint8 a);

/* Set the leading transition for CLIP_ID (applied between it and the previous
 * clip on the same track).  TYPE == CMACS_VID_TRANS_NONE removes it. */
extern gboolean cmacs_vidstudio_proj_set_transition (CmacsVidProject *p,
                                                     gint clip_id, int type,
                                                     int overlap_frames,
                                                     int easing);
/* Append an effect (CMACS_VID_FX_*) to CLIP_ID's effect chain. */
extern gboolean cmacs_vidstudio_proj_add_effect (CmacsVidProject *p,
                                                 gint clip_id, int type);
extern gboolean cmacs_vidstudio_proj_clear_effects (CmacsVidProject *p,
                                                    gint clip_id);

/* Editing. */
extern gboolean cmacs_vidstudio_proj_set_clip_duration (CmacsVidProject *p,
                                                        gint clip_id,
                                                        int frames);
/* Split CLIP_ID at AT_FRAME (relative to the clip start); returns the new
 * clip id for the tail, or -1. */
extern gint cmacs_vidstudio_proj_split_clip (CmacsVidProject *p, gint clip_id,
                                             int at_frame);
extern gboolean cmacs_vidstudio_proj_move_clip (CmacsVidProject *p,
                                                gint clip_id, guint new_track,
                                                guint new_index);
/* Remove CLIP_ID.  RIPPLE TRUE shifts later clips earlier; FALSE leaves a
 * transparent gap of equal duration. */
extern gboolean cmacs_vidstudio_proj_remove_clip (CmacsVidProject *p,
                                                  gint clip_id,
                                                  gboolean ripple);

/* Per-clip query. */
extern gint cmacs_vidstudio_proj_clip_at (CmacsVidProject *p, guint track,
                                          guint index);
extern gint cmacs_vidstudio_proj_clip_duration (CmacsVidProject *p,
                                                gint clip_id);
extern gint cmacs_vidstudio_proj_clip_start_frame (CmacsVidProject *p,
                                                   gint clip_id);
/* TRUE once CLIP-ID's frames are decoded (video clips decode on a worker
   thread; the preview shows a placeholder until then).  Non-video clips
   and unknown ids are always TRUE. */
extern gboolean cmacs_vidstudio_proj_clip_ready (CmacsVidProject *p,
                                                 gint clip_id);

/* Preview: render FRAME and return PNG bytes (g_malloc'd; caller g_free's). */
extern guint8 *cmacs_vidstudio_proj_render_png (CmacsVidProject *p, int frame,
                                                gsize *out_n);
/* Playback preview: render FRAME as binary PPM (P6), downscaled to MAX-W
   pixels wide when positive.  Uncompressed -- much faster than PNG. */
extern guint8 *cmacs_vidstudio_proj_render_ppm (CmacsVidProject *p, int frame,
                                                int max_w, gsize *out_n);
/* Read a composited pixel at FRAME (for tests).  FALSE if out of range. */
extern gboolean cmacs_vidstudio_proj_frame_pixel (CmacsVidProject *p, int frame,
                                                  int x, int y, guint8 *r,
                                                  guint8 *g, guint8 *b,
                                                  guint8 *a);

/* Export (synchronous).  CODEC: 0 h264, 1 vp9, 2 h265, 3 prores. */
extern gboolean cmacs_vidstudio_proj_export_video (CmacsVidProject *p,
                                                   const char *path, int codec,
                                                   char **error_msg);
extern gboolean cmacs_vidstudio_proj_export_gif (CmacsVidProject *p,
                                                 const char *path,
                                                 char **error_msg);

/* Live viewport: render FRAME and return an owned GrlImage* (transfer full)
   as void* (raylib-free DEFUN layer).  Caller passes it to the render ctx. */
extern void *cmacs_vidstudio_proj_canvas_image (CmacsVidProject *p, int frame);

/* Per-clip transform / opacity / blend / effect params. */
extern gboolean cmacs_vidstudio_proj_set_opacity (CmacsVidProject *p,
                                                  gint clip_id, double o);
extern gboolean cmacs_vidstudio_proj_set_transform (CmacsVidProject *p,
                                                    gint clip_id, double x,
                                                    double y, double sx,
                                                    double sy, double rot);
extern gboolean cmacs_vidstudio_proj_set_anchor (CmacsVidProject *p,
                                                 gint clip_id, double ax,
                                                 double ay);
/* Blend mode == LrgReelBlendMode: 0 normal,1 multiply,2 screen,3 overlay,
   4 soft-light,5 add,6 color-dodge,7 color-burn. */
extern gboolean cmacs_vidstudio_proj_set_blend_mode (CmacsVidProject *p,
                                                     gint clip_id, int mode);
extern gboolean cmacs_vidstudio_proj_set_effect_param (CmacsVidProject *p,
                                                       gint clip_id,
                                                       int effect_index,
                                                       const char *prop,
                                                       double value);
/* Video-clip controls (no-op / FALSE on non-video clips). */
extern gboolean cmacs_vidstudio_proj_set_video_fit (CmacsVidProject *p,
                                                    gint clip_id, int fit);
extern gboolean cmacs_vidstudio_proj_set_video_rate (CmacsVidProject *p,
                                                     gint clip_id, double rate);
extern gboolean cmacs_vidstudio_proj_set_video_loop (CmacsVidProject *p,
                                                     gint clip_id,
                                                     gboolean loop);
/* Export quality (applied to the next video export). */
extern void cmacs_vidstudio_proj_set_export_quality (CmacsVidProject *p,
                                                     int crf, int bitrate_kbps);
/* Render one FRAME straight to PATH (PNG/JPG by extension). */
extern gboolean cmacs_vidstudio_proj_export_still (CmacsVidProject *p,
                                                   int frame, const char *path,
                                                   char **error_msg);

/* ── Audio lane ─────────────────────────────────────────────────────────── */
extern gint cmacs_vidstudio_proj_add_audio_file (CmacsVidProject *p,
                                                 const char *path,
                                                 int from_frame, double volume,
                                                 double trim_start,
                                                 double trim_end,
                                                 char **error_msg);
/* Extract CLIP_ID's audio (video clip) and add it to the lane. */
extern gint cmacs_vidstudio_proj_add_audio_from_clip (CmacsVidProject *p,
                                                      gint clip_id,
                                                      int from_frame,
                                                      double volume,
                                                      char **error_msg);
extern gboolean cmacs_vidstudio_proj_set_audio_volume (CmacsVidProject *p,
                                                       gint id, double v);
extern gboolean cmacs_vidstudio_proj_set_audio_fade (CmacsVidProject *p,
                                                     gint id, double fade_in,
                                                     double fade_out);
extern gboolean cmacs_vidstudio_proj_remove_audio (CmacsVidProject *p, gint id);
extern guint cmacs_vidstudio_proj_audio_count (CmacsVidProject *p);
/* FORMAT: 0 WAV, 1 MP3, 2 AAC, 3 FLAC. */
extern gboolean cmacs_vidstudio_proj_export_audio (CmacsVidProject *p,
                                                   const char *path, int format,
                                                   char **error_msg);

#endif /* HAVE_CMACS_VIDSTUDIO */
#endif /* CMACS_VIDSTUDIO_PROJ_H */
