/* cmacs-vidstudio-proj.c --- libregnum Reel-based video project bridge.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The only vidstudio TU that includes <libregnum.h>.  Models an editable
 * timeline (tracks of clip segments + transitions) and rebuilds it into an
 * LrgReel (one LrgReelTransitionSeries per track) for rendering / export. */

#include <config.h>

#ifdef HAVE_CMACS_VIDSTUDIO

#include "cmacs-vidstudio-proj.h"
#include <libregnum.h>
#include <string.h>

/* Animatable parameter codes (cmacs_vidstudio_proj_add_keyframe `param'). */
enum
{
  CMACS_VID_KF_OPACITY = 0,
  CMACS_VID_KF_X,
  CMACS_VID_KF_Y,
  CMACS_VID_KF_SCALE,
  CMACS_VID_KF_ROTATION,
  CMACS_VID_KF_EFFECT_PARAM      /* uses effect_index + prop */
};

/* One keyframe.  FRAME is clip-relative (survives clip moves/splits). */
typedef struct
{
  int    param;
  int    effect_index;
  char  *prop;                  /* effect-param only, else NULL */
  double frame;
  double value;
  int    easing;                /* LrgEasingType */
} VidKey;

/* Clip kind, recorded for save/load (the LrgReelClip alone can't reproduce
   its creation params portably). */
enum { CMACS_VID_KIND_SOLID = 0, CMACS_VID_KIND_IMAGE, CMACS_VID_KIND_VIDEO,
       CMACS_VID_KIND_TEXT };

typedef struct
{
  guint               id;
  LrgReelClip        *clip;     /* owned */
  LrgReelTransition  *trans;    /* owned, or NULL (leading transition) */
  int                 duration; /* frames */
  int                 trans_overlap;
  int                 trans_type;   /* recorded transition kind, or -1 */
  int                 trans_easing;
  GArray             *keys;     /* of VidKey, or NULL until first keyframe */
  GPtrArray          *curves;   /* of VidCurve*, rebuilt when keys_dirty */
  gboolean            keys_dirty;
  /* Creation descriptor (for serialization). */
  int                 kind;
  char               *asset;    /* image/video path or text string */
  guint8              col[4];   /* solid / text colour */
  double              in_sec, out_sec;   /* video slice */
} VidSeg;

/* One animatable channel = a keyframe curve for a (param, effect, prop). */
typedef struct
{
  int    param;
  int    effect_index;
  char  *prop;
  LrgKeyframeCurve *curve;      /* owned */
} VidCurve;

typedef struct
{
  GArray *segs;                 /* of VidSeg (clear-func unrefs clip+trans) */
} VidTrack;

/* An audio clip on the (single, flat) audio lane.  One LrgReelAudioTrack mixes
   all of them (overlapping clips accumulate), so a flat lane suffices for v1. */
typedef struct
{
  guint        id;
  char        *source_path;     /* audio file, or the source VIDEO path when
                                   EXTRACT is set (audio pulled from a video) */
  gboolean     extract;         /* TRUE: source_path is a video, extract audio */
  LrgWaveData *wave;            /* owned; set for clip-extracted audio */
  int          from_frame;
  double       volume;
  double       trim_start, trim_end;
  double       fade_in, fade_out;   /* seconds; 0 = none */
  double       duration_secs;       /* natural length (for the timeline) */
} VidAudioSeg;

struct CmacsVidProject
{
  int        width;
  int        height;
  double     fps;
  GPtrArray *tracks;            /* of VidTrack* */
  guint      next_id;
  LrgReel   *reel;              /* rebuilt lazily from the tracks */
  gboolean   dirty;
  int        export_crf;        /* video CRF quality; <0 = exporter default */
  int        export_bitrate;    /* video bitrate kbps; <=0 = unset */
  char      *export_preset;     /* x264/x265 preset word; NULL = default */
  GArray      *audio;           /* of VidAudioSeg */
  LrgWaveData *mixed;           /* cached mix, or NULL (invalidated on edit) */
  gboolean     audio_dirty;
  guint        audio_sample_rate;
  guint        audio_channels;
};

/* Forward decls (definitions appear later in the file). */
static void proj_rebuild (CmacsVidProject *p);
static gboolean find_seg (CmacsVidProject *p, gint id, VidTrack **out_track,
                          guint *out_index);
static void seg_meta (CmacsVidProject *p, gint id, int kind, const char *asset,
                      guint8 r, guint8 g, guint8 b, guint8 a,
                      double in, double out);
static void proj_apply_animation (CmacsVidProject *p, int global_frame);
static gboolean proj_has_keyframes (CmacsVidProject *p);
static gboolean proj_has_video (CmacsVidProject *p);
static gboolean proj_render_to_exporter (CmacsVidProject *p,
                                         LrgReelRenderer *r,
                                         LrgReelExporter *ex, GError **error);

static void
vidkey_clear (gpointer p)
{
  VidKey *k = p;
  g_clear_pointer (&k->prop, g_free);
}

static void
vidcurve_free (gpointer p)
{
  VidCurve *c = p;
  g_clear_pointer (&c->prop, g_free);
  g_clear_object (&c->curve);
  g_free (c);
}

static void
vidseg_clear (gpointer p)
{
  VidSeg *s = p;
  g_clear_object (&s->clip);
  g_clear_object (&s->trans);
  g_clear_pointer (&s->keys, g_array_unref);
  g_clear_pointer (&s->curves, g_ptr_array_unref);
  g_clear_pointer (&s->asset, g_free);
}

static void
vidaudio_clear (gpointer p)
{
  VidAudioSeg *a = p;
  g_clear_pointer (&a->source_path, g_free);
  g_clear_object (&a->wave);
}

static VidTrack *
track_new (void)
{
  VidTrack *t = g_new0 (VidTrack, 1);
  t->segs = g_array_new (FALSE, FALSE, sizeof (VidSeg));
  g_array_set_clear_func (t->segs, vidseg_clear);
  return t;
}

static void
track_free (gpointer p)
{
  VidTrack *t = p;
  g_array_unref (t->segs);
  g_free (t);
}

CmacsVidProject *
cmacs_vidstudio_proj_new (int w, int h, double fps)
{
  CmacsVidProject *p;

  if (w <= 0 || h <= 0 || fps <= 0.0)
    return NULL;
  p = g_new0 (CmacsVidProject, 1);
  p->width = w;
  p->height = h;
  p->fps = fps;
  p->tracks = g_ptr_array_new_with_free_func (track_free);
  p->next_id = 0;
  p->export_crf = -1;
  p->export_bitrate = 0;
  p->reel = NULL;
  p->dirty = TRUE;
  p->audio = g_array_new (FALSE, FALSE, sizeof (VidAudioSeg));
  g_array_set_clear_func (p->audio, vidaudio_clear);
  p->mixed = NULL;
  p->audio_dirty = TRUE;
  p->audio_sample_rate = 44100;
  p->audio_channels = 2;
  /* Start with one track. */
  g_ptr_array_add (p->tracks, track_new ());
  return p;
}

void
cmacs_vidstudio_proj_free (CmacsVidProject *p)
{
  g_free (p->export_preset);
  if (p == NULL)
    return;
  g_clear_pointer (&p->tracks, g_ptr_array_unref);
  g_clear_pointer (&p->audio, g_array_unref);
  g_clear_object (&p->mixed);
  g_clear_object (&p->reel);
  g_free (p);
}

int cmacs_vidstudio_proj_width  (CmacsVidProject *p) { return p ? p->width : 0; }
int cmacs_vidstudio_proj_height (CmacsVidProject *p) { return p ? p->height : 0; }
double cmacs_vidstudio_proj_fps (CmacsVidProject *p) { return p ? p->fps : 0.0; }

static VidTrack *
track_at (CmacsVidProject *p, guint i)
{
  if (p == NULL || i >= p->tracks->len)
    return NULL;
  return g_ptr_array_index (p->tracks, i);
}

/* Total length of a track in frames (durations minus transition overlaps). */
static int
track_total (VidTrack *t)
{
  int total = 0;
  guint i;

  for (i = 0; i < t->segs->len; i++)
    {
      VidSeg *s = &g_array_index (t->segs, VidSeg, i);
      total += s->duration;
      if (i > 0 && s->trans != NULL)
        total -= s->trans_overlap;
    }
  return total < 0 ? 0 : total;
}

int
cmacs_vidstudio_proj_total_frames (CmacsVidProject *p)
{
  int max = 0;
  guint i;

  if (p == NULL)
    return 0;
  for (i = 0; i < p->tracks->len; i++)
    {
      int tt = track_total (g_ptr_array_index (p->tracks, i));
      if (tt > max)
        max = tt;
    }
  return max;
}

guint
cmacs_vidstudio_proj_add_track (CmacsVidProject *p)
{
  g_return_val_if_fail (p != NULL, 0);
  g_ptr_array_add (p->tracks, track_new ());
  p->dirty = TRUE;
  return p->tracks->len - 1;
}

guint
cmacs_vidstudio_proj_n_tracks (CmacsVidProject *p)
{
  return p ? p->tracks->len : 0;
}

guint
cmacs_vidstudio_proj_track_clip_count (CmacsVidProject *p, guint track)
{
  VidTrack *t = track_at (p, track);
  return t ? t->segs->len : 0;
}

gint
cmacs_vidstudio_proj_track_total_frames (CmacsVidProject *p, guint track)
{
  VidTrack *t = track_at (p, track);
  return t ? track_total (t) : 0;
}

/* Append CLIP (transfer full) to TRACK with DURATION frames; returns id. */
static gint
append_clip (CmacsVidProject *p, guint track, LrgReelClip *clip, int duration)
{
  VidTrack *t = track_at (p, track);
  VidSeg seg;

  if (t == NULL || clip == NULL)
    {
      g_clear_object (&clip);
      return -1;
    }
  if (duration <= 0)
    duration = (int) (p->fps * 3.0 + 0.5);  /* default 3s */
  lrg_reel_clip_set_duration_in_frames (clip, duration);

  memset (&seg, 0, sizeof seg);
  seg.id = p->next_id++;
  seg.clip = clip;  /* takes the ref */
  seg.trans = NULL;
  seg.duration = duration;
  seg.trans_overlap = 0;
  seg.trans_type = -1;
  g_array_append_val (t->segs, seg);
  p->dirty = TRUE;
  return (gint) seg.id;
}

/* Record the creation descriptor on a seg (for save/load). */
static void
seg_meta (CmacsVidProject *p, gint id, int kind, const char *asset,
          guint8 r, guint8 g, guint8 b, guint8 a, double in, double out)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;
  if (id < 0 || !find_seg (p, id, &t, &si))
    return;
  s = &g_array_index (t->segs, VidSeg, si);
  s->kind = kind;
  g_clear_pointer (&s->asset, g_free);
  s->asset = asset ? g_strdup (asset) : NULL;
  s->col[0] = r; s->col[1] = g; s->col[2] = b; s->col[3] = a;
  s->in_sec = in; s->out_sec = out;
}

gint
cmacs_vidstudio_proj_add_solid_clip (CmacsVidProject *p, guint track,
                                     int duration, guint8 r, guint8 g,
                                     guint8 b, guint8 a)
{
  GrlColor col;
  gint id;
  col.r = r; col.g = g; col.b = b; col.a = a;
  id = append_clip (p, track,
                    LRG_REEL_CLIP (lrg_reel_solid_clip_new (&col)), duration);
  seg_meta (p, id, CMACS_VID_KIND_SOLID, NULL, r, g, b, a, 0, 0);
  return id;
}

gint
cmacs_vidstudio_proj_add_gradient_clip (CmacsVidProject *p, guint track,
                                        int duration, gboolean radial,
                                        guint8 ar, guint8 ag, guint8 ab,
                                        guint8 aa, guint8 br, guint8 bg,
                                        guint8 bb, guint8 ba)
{
  GrlColor a, b;
  LrgReelGradientClip *clip;
  gint id;

  a.r = ar; a.g = ag; a.b = ab; a.a = aa;
  b.r = br; b.g = bg; b.b = bb; b.a = ba;
  clip = radial ? lrg_reel_gradient_clip_new_radial (&a, &b)
                : lrg_reel_gradient_clip_new_linear (&a, &b,
                                                     GRL_GRADIENT_AXIS_VERTICAL);
  id = append_clip (p, track, LRG_REEL_CLIP (clip), duration);
  /* Gradient clips serialize their kind + start colour only (v1 gap: the end
     colour + radial flag are not persisted). */
  seg_meta (p, id, CMACS_VID_KIND_SOLID, NULL, ar, ag, ab, aa, 0, 0);
  return id;
}

gint
cmacs_vidstudio_proj_add_shape_rect (CmacsVidProject *p, guint track,
                                     int duration, int x, int y, int w, int h,
                                     guint8 r, guint8 g, guint8 b, guint8 a)
{
  LrgReelShapeClip *c = lrg_reel_shape_clip_new_rect (x, y, w, h);
  GrlColor col;
  col.r = r; col.g = g; col.b = b; col.a = a;
  lrg_reel_shape_clip_set_fill_color (c, &col);
  return append_clip (p, track, LRG_REEL_CLIP (c), duration);
}

gint
cmacs_vidstudio_proj_add_shape_circle (CmacsVidProject *p, guint track,
                                       int duration, int cx, int cy, int radius,
                                       guint8 r, guint8 g, guint8 b, guint8 a)
{
  LrgReelShapeClip *c = lrg_reel_shape_clip_new_circle (cx, cy, radius);
  GrlColor col;
  col.r = r; col.g = g; col.b = b; col.a = a;
  lrg_reel_shape_clip_set_fill_color (c, &col);
  return append_clip (p, track, LRG_REEL_CLIP (c), duration);
}

gint
cmacs_vidstudio_proj_add_caption (CmacsVidProject *p, guint track, int duration,
                                  const char *srt_path, int font_size,
                                  guint8 r, guint8 g, guint8 b, guint8 a,
                                  char **error_msg)
{
  LrgReelCaptionClip *c;
  GrlColor col;
  g_autoptr (GError) err = NULL;

  c = lrg_reel_caption_clip_new_from_srt (srt_path, &err);
  if (c == NULL)
    { if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not load captions");
      return -1; }
  if (font_size > 0)
    lrg_reel_caption_clip_set_font_size (c, font_size);
  col.r = r; col.g = g; col.b = b; col.a = a;
  lrg_reel_caption_clip_set_color (c, &col);
  return append_clip (p, track, LRG_REEL_CLIP (c), duration);
}

/* Animated text clip: a functional LrgReelClip whose per-frame render callback
   rasterises TEXT character-by-character onto the CPU canvas image (so it
   renders identically in preview, export and the live viewport), applying an
   LrgTextEffect (typewriter reveal / wave / rainbow / shake / fade / pulse)
   per character.  Drawing via the built-in bitmap font needs no GL context and
   no font object -- unlike lrg_rich_text_draw, which is immediate-mode GL and
   is lost in the CPU reel pipeline. */
typedef struct
{
  char          *text;          /* owned plain UTF-8 string */
  LrgTextEffect *effect;        /* owned, or NULL for no animation */
  int            font_size;
  GrlColor       color;
  gfloat         x, y;
} CmacsVidAnimText;

static void
animtext_render (LrgReelClip *clip, LrgReelContext *ctx,
                 LrgImageCanvas *canvas, gpointer user_data)
{
  CmacsVidAnimText *a = user_data;
  GrlImage *img = canvas ? lrg_image_canvas_get_image (canvas) : NULL;
  gint frame = lrg_reel_context_get_frame (ctx);
  gdouble fps = lrg_reel_context_get_fps (ctx);
  const char *p;
  guint idx = 0;
  gfloat penx;
  (void) clip;

  if (img == NULL || a->text == NULL)
    return;
  penx = a->x;
  /* Reset + advance to the absolute clip time so seeking is deterministic. */
  if (a->effect != NULL)
    {
      lrg_text_effect_reset (a->effect);
      lrg_text_effect_update (a->effect,
                              fps > 0.0 ? (gfloat) (frame / fps) : 0.0f);
    }
  for (p = a->text; *p != '\0'; p = g_utf8_next_char (p), idx++)
    {
      gunichar uc = g_utf8_get_char (p);
      char ch[8];
      gint clen = g_unichar_to_utf8 (uc, ch);
      gfloat ox = 0.0f, oy = 0.0f;
      guint8 r = a->color.r, g = a->color.g, b = a->color.b, al = a->color.a;
      g_autoptr (GrlVector2) m = NULL;
      ch[clen] = '\0';
      m = grl_image_measure_text_bitmap (ch, a->font_size);
      if (a->effect != NULL)
        lrg_text_effect_apply (a->effect, idx, &ox, &oy, &r, &g, &b, &al);
      if (al > 0)                       /* typewriter hides chars via alpha 0 */
        {
          GrlColor col;
          col.r = r; col.g = g; col.b = b; col.a = al;
          grl_image_draw_text_bitmap (img, ch, (gint) (penx + ox),
                                      (gint) (a->y + oy), a->font_size, &col);
        }
      penx += (m != NULL) ? grl_vector2_get_x (m) : (gfloat) a->font_size;
    }
}

static void
animtext_free (gpointer user_data)
{
  CmacsVidAnimText *a = user_data;
  g_free (a->text);
  g_clear_object (&a->effect);
  g_free (a);
}

/* EFFECT_TYPE is an LrgTextEffectType (0 none, 1 shake, 2 wave, 3 rainbow,
   4 typewriter, 5 fade-in, 6 pulse). */
gint
cmacs_vidstudio_proj_add_rich_text_clip (CmacsVidProject *p, guint track,
                                         const char *text, int duration,
                                         int font_size, int effect_type,
                                         guint8 r, guint8 g, guint8 b, guint8 a)
{
  CmacsVidAnimText *at = g_new0 (CmacsVidAnimText, 1);
  LrgReelClip *clip;
  gint id;
  long nchars;

  at->text = g_strdup (text ? text : "");
  at->font_size = font_size > 0 ? font_size : 32;
  at->color.r = r; at->color.g = g; at->color.b = b; at->color.a = a;
  at->x = 20.0f;
  at->y = (gfloat) (p->height / 2 - at->font_size / 2);
  if (effect_type > 0)
    {
      at->effect = lrg_text_effect_new ((LrgTextEffectType) effect_type);
      nchars = g_utf8_strlen (at->text, -1);
      lrg_text_effect_set_char_count (at->effect, (guint) MAX (1, nchars));
    }
  clip = lrg_reel_clip_new_with_func (animtext_render, at, animtext_free);
  id = append_clip (p, track, clip, duration);
  seg_meta (p, id, CMACS_VID_KIND_TEXT, text, r, g, b, a, 0, 0);
  return id;
}

/* Wrap a video source in a loop or freeze sequence (a nested clip).  MODE 0 =
   loop (repeat every LOOP_FRAMES over DURATION); MODE 1 = freeze (hold the
   frame at PARAM seconds).  DURATION is the on-timeline length in frames. */
static gint
proj_add_sequence_video (CmacsVidProject *p, guint track, const char *path,
                         int duration, int mode, double param,
                         char **error_msg)
{
  LrgReelVideoClip *vclip;
  LrgReelVideoSource *src;
  LrgReelSequence *seq;
  g_autoptr (GError) err = NULL;
  gint id;

  vclip = lrg_reel_video_clip_new_from_file (path, &err);
  if (vclip == NULL)
    { if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not load video");
      return -1; }
  src = lrg_reel_video_clip_get_source (vclip);
  lrg_reel_video_source_set_async_decode (src, TRUE);
  lrg_reel_video_source_get_frame_count (src);
  if (mode == 1)
    seq = lrg_reel_sequence_new_freeze ((gint) (param * p->fps + 0.5));
  else
    seq = lrg_reel_sequence_new_loop (param > 0.0 ? (gint) (param * p->fps + 0.5)
                                                  : duration, 0);
  lrg_reel_sequence_add_child (seq, LRG_REEL_CLIP (vclip));
  g_object_unref (vclip);                 /* the sequence holds a ref now */
  id = append_clip (p, track, LRG_REEL_CLIP (seq), duration);
  seg_meta (p, id, CMACS_VID_KIND_VIDEO, path, 0, 0, 0, 0, 0, 0);
  return id;
}

gint
cmacs_vidstudio_proj_add_loop_clip (CmacsVidProject *p, guint track,
                                    const char *path, int duration,
                                    double loop_secs, char **error_msg)
{
  return proj_add_sequence_video (p, track, path, duration, 0, loop_secs,
                                  error_msg);
}

gint
cmacs_vidstudio_proj_add_freeze_clip (CmacsVidProject *p, guint track,
                                      const char *path, int duration,
                                      double freeze_secs, char **error_msg)
{
  return proj_add_sequence_video (p, track, path, duration, 1, freeze_secs,
                                  error_msg);
}

gint
cmacs_vidstudio_proj_add_image_clip (CmacsVidProject *p, guint track,
                                     const char *path, int duration,
                                     char **error_msg)
{
  LrgReelImageClip *clip;
  g_autoptr (GError) err = NULL;

  clip = lrg_reel_image_clip_new_from_file (path, &err);
  if (clip == NULL)
    {
      if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not load image");
      return -1;
    }
  {
    gint id = append_clip (p, track, LRG_REEL_CLIP (clip), duration);
    seg_meta (p, id, CMACS_VID_KIND_IMAGE, path, 0, 0, 0, 0, 0, 0);
    return id;
  }
}

gint
cmacs_vidstudio_proj_add_video_clip (CmacsVidProject *p, guint track,
                                     const char *path, double in_sec,
                                     double out_sec, char **error_msg)
{
  LrgReelVideoClip *clip;
  LrgReelVideoSource *src;
  double src_dur, in, out;
  int frames;
  g_autoptr (GError) err = NULL;

  clip = lrg_reel_video_clip_new_from_file (path, &err);
  if (clip == NULL)
    {
      if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not load video");
      return -1;
    }
  src = lrg_reel_video_clip_get_source (clip);

  /* Resolve whole-video / in-out slice.  get_duration is ffprobe-derived at
     construction (seconds, decode-free).  Blank/negative IN -> 0 (start);
     blank/<=0 or out-of-range OUT -> source end.  This is the ONLY place the
     source is reachable, so "whole video" becomes a concrete positive frame
     count HERE -- bypassing the Lisp --secs-to-frames (max 1 ...) clamp and
     append_clip's (duration <= 0 -> 3s) reinterpretation.  trim_start/_end
     record the slice as engine state (survives later duration edits and
     serialises for save/load). */
  src_dur = lrg_reel_video_source_get_duration (src);
  in  = (in_sec < 0.0) ? 0.0 : in_sec;
  out = (out_sec <= 0.0 || (src_dur > 0.0 && out_sec > src_dur))
          ? src_dur : out_sec;
  if (src_dur > 0.0 && out <= in)
    out = src_dur;
  lrg_reel_video_clip_set_trim_start (clip, in);
  lrg_reel_video_clip_set_trim_end (clip, out);
  frames = (int) ((out - in) * p->fps + 0.5);   /* playback rate 1.0 for v1 */
  if (frames < 1)
    frames = 1;

  /* Decode on a worker thread: preview shows a placeholder until ready
     (poll cmacs_vidstudio_proj_clip_ready), so adding a clip never blocks
     the editor.  Export forces real frames via wait_video_clips.  The
     frame-count call kicks the worker NOW (it otherwise starts on first
     frame access), so readiness polling never waits on a render. */
  lrg_reel_video_source_set_async_decode (src, TRUE);
  lrg_reel_video_source_get_frame_count (src);
  {
    gint id = append_clip (p, track, LRG_REEL_CLIP (clip), frames);
    seg_meta (p, id, CMACS_VID_KIND_VIDEO, path, 0, 0, 0, 0, in, out);
    return id;
  }
}

gint
cmacs_vidstudio_proj_add_text_clip (CmacsVidProject *p, guint track,
                                    const char *text, int duration,
                                    guint8 r, guint8 g, guint8 b, guint8 a)
{
  LrgReelTextClip *clip;
  GrlColor col;

  clip = lrg_reel_text_clip_new (text != NULL ? text : "");
  if (clip == NULL)
    return -1;
  col.r = r; col.g = g; col.b = b; col.a = a;
  lrg_reel_text_clip_set_color (clip, &col);
  {
    gint id = append_clip (p, track, LRG_REEL_CLIP (clip), duration);
    seg_meta (p, id, CMACS_VID_KIND_TEXT, text, r, g, b, a, 0, 0);
    return id;
  }
}

/* Locate the segment with ID; returns its track + index, or FALSE. */
static gboolean
find_seg (CmacsVidProject *p, gint id, VidTrack **out_track, guint *out_index)
{
  guint ti, si;

  if (p == NULL || id < 0)
    return FALSE;
  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      for (si = 0; si < t->segs->len; si++)
        if (g_array_index (t->segs, VidSeg, si).id == (guint) id)
          {
            if (out_track) *out_track = t;
            if (out_index) *out_index = si;
            return TRUE;
          }
    }
  return FALSE;
}

static LrgReelTransition *
make_transition (int type, int easing)
{
  GType gt;
  LrgReelTransition *tr;

  switch (type)
    {
    case CMACS_VID_TRANS_FADE:       gt = LRG_TYPE_REEL_FADE_TRANSITION; break;
    case CMACS_VID_TRANS_DISSOLVE:   gt = LRG_TYPE_REEL_DISSOLVE_TRANSITION; break;
    case CMACS_VID_TRANS_WIPE:       gt = LRG_TYPE_REEL_WIPE_TRANSITION; break;
    case CMACS_VID_TRANS_SLIDE:      gt = LRG_TYPE_REEL_SLIDE_TRANSITION; break;
    case CMACS_VID_TRANS_ZOOM:       gt = LRG_TYPE_REEL_ZOOM_TRANSITION; break;
    case CMACS_VID_TRANS_IRIS:       gt = LRG_TYPE_REEL_IRIS_TRANSITION; break;
    case CMACS_VID_TRANS_FLIP:       gt = LRG_TYPE_REEL_FLIP_TRANSITION; break;
    case CMACS_VID_TRANS_PUSH:       gt = LRG_TYPE_REEL_PUSH_TRANSITION; break;
    case CMACS_VID_TRANS_CLOCK_WIPE: gt = LRG_TYPE_REEL_CLOCK_WIPE_TRANSITION; break;
    default: return NULL;
    }
  tr = g_object_new (gt, NULL);
  if (tr != NULL)
    lrg_reel_transition_set_easing (tr, (LrgEasingType) easing);
  return tr;
}

gboolean
cmacs_vidstudio_proj_set_transition (CmacsVidProject *p, gint clip_id,
                                     int type, int overlap_frames, int easing)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  g_clear_object (&s->trans);
  s->trans_type = type;
  s->trans_easing = easing;
  if (type >= 0)
    {
      s->trans = make_transition (type, easing);
      s->trans_overlap = overlap_frames < 0 ? 0 : overlap_frames;
    }
  else
    {
      s->trans_overlap = 0;
    }
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_add_effect (CmacsVidProject *p, gint clip_id, int type)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;
  GType gt;
  LrgReelEffect *fx;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  switch (type)
    {
    case CMACS_VID_FX_BLUR:        gt = LRG_TYPE_REEL_BLUR_EFFECT; break;
    case CMACS_VID_FX_BLOOM:       gt = LRG_TYPE_REEL_BLOOM_EFFECT; break;
    case CMACS_VID_FX_COLOR_GRADE: gt = LRG_TYPE_REEL_COLOR_GRADE_EFFECT; break;
    case CMACS_VID_FX_VIGNETTE:    gt = LRG_TYPE_REEL_VIGNETTE_EFFECT; break;
    case CMACS_VID_FX_GRAIN:       gt = LRG_TYPE_REEL_GRAIN_EFFECT; break;
    default: return FALSE;
    }
  s = &g_array_index (t->segs, VidSeg, si);
  fx = g_object_new (gt, NULL);
  if (fx == NULL)
    return FALSE;
  /* The clip takes ownership of the effect. */
  lrg_reel_clip_add_effect (s->clip, fx);
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_clear_effects (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t = NULL;
  guint si = 0;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  lrg_reel_clip_clear_effects (g_array_index (t->segs, VidSeg, si).clip);
  p->dirty = TRUE;
  return TRUE;
}

/* ── Per-clip transform / opacity / blend / effect params ──────────────── */

/* The LrgReelClip for CLIP_ID, or NULL. */
static LrgReelClip *
seg_clip (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t = NULL;
  guint si = 0;
  if (!find_seg (p, clip_id, &t, &si))
    return NULL;
  return g_array_index (t->segs, VidSeg, si).clip;
}

gboolean
cmacs_vidstudio_proj_set_opacity (CmacsVidProject *p, gint clip_id, double o)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL) return FALSE;
  lrg_reel_clip_set_opacity (c, o);
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_set_transform (CmacsVidProject *p, gint clip_id,
                                    double x, double y, double sx, double sy,
                                    double rot)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL) return FALSE;
  lrg_reel_clip_set_transform (c, x, y, sx, sy, rot);
  p->dirty = TRUE;
  return TRUE;
}

/* Draw CLIP-ID into an explicit sub-rectangle (picture-in-picture overlay)
   instead of the full frame.  Works for video + image clips; w/h <= 0 clears
   it (video) / is passed through (image).  The clip still composites over the
   tracks below, so an overlay on a higher track appears as a small window. */
gboolean
cmacs_vidstudio_proj_set_clip_box (CmacsVidProject *p, gint clip_id,
                                   int x, int y, int w, int h)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL) return FALSE;
  if (LRG_IS_REEL_VIDEO_CLIP (c))
    lrg_reel_video_clip_set_box (LRG_REEL_VIDEO_CLIP (c), x, y, w, h);
  else if (LRG_IS_REEL_IMAGE_CLIP (c))
    lrg_reel_image_clip_set_box (LRG_REEL_IMAGE_CLIP (c), x, y, w, h);
  else
    return FALSE;
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_set_anchor (CmacsVidProject *p, gint clip_id,
                                 double ax, double ay)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL) return FALSE;
  lrg_reel_clip_set_anchor (c, ax, ay);
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_set_blend_mode (CmacsVidProject *p, gint clip_id,
                                     int mode)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL) return FALSE;
  lrg_reel_clip_set_blend_mode (c, (LrgReelBlendMode) mode);
  p->dirty = TRUE;
  return TRUE;
}

/* Set a numeric property PROP of effect EFFECT_INDEX on CLIP_ID to VALUE.
   The value is transformed into the property's actual type (int/float/double),
   so callers pass a double regardless of the pspec type. */
gboolean
cmacs_vidstudio_proj_set_effect_param (CmacsVidProject *p, gint clip_id,
                                       int effect_index, const char *prop,
                                       double value)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  LrgReelEffect *fx;
  GParamSpec *pspec;
  GValue val = G_VALUE_INIT, dval = G_VALUE_INIT;

  if (c == NULL || prop == NULL)
    return FALSE;
  fx = lrg_reel_clip_get_effect (c, (guint) effect_index);
  if (fx == NULL)
    return FALSE;
  pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (fx), prop);
  if (pspec == NULL)
    return FALSE;
  g_value_init (&val, G_PARAM_SPEC_VALUE_TYPE (pspec));
  g_value_init (&dval, G_TYPE_DOUBLE);
  g_value_set_double (&dval, value);
  if (g_value_transform (&dval, &val))
    g_object_set_property (G_OBJECT (fx), prop, &val);
  g_value_unset (&val);
  g_value_unset (&dval);
  p->dirty = TRUE;
  return TRUE;
}

/* ── Video-clip controls: fit, playback rate, loop ─────────────────────── */

gboolean
cmacs_vidstudio_proj_set_video_fit (CmacsVidProject *p, gint clip_id, int fit)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL || !LRG_IS_REEL_VIDEO_CLIP (c)) return FALSE;
  lrg_reel_video_clip_set_fit (LRG_REEL_VIDEO_CLIP (c), (LrgReelFit) fit);
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_set_video_rate (CmacsVidProject *p, gint clip_id,
                                     double rate)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL || !LRG_IS_REEL_VIDEO_CLIP (c)) return FALSE;
  lrg_reel_video_clip_set_playback_rate (LRG_REEL_VIDEO_CLIP (c), rate);
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_set_video_loop (CmacsVidProject *p, gint clip_id,
                                     gboolean loop)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  if (c == NULL || !LRG_IS_REEL_VIDEO_CLIP (c)) return FALSE;
  lrg_reel_video_clip_set_loop (LRG_REEL_VIDEO_CLIP (c), loop);
  p->dirty = TRUE;
  return TRUE;
}

/* Render a single FRAME straight to PATH (PNG/JPG by extension). */
gboolean
cmacs_vidstudio_proj_export_still (CmacsVidProject *p, int frame,
                                   const char *path, char **error_msg)
{
  LrgReelRenderer *r;
  g_autoptr (GError) err = NULL;
  gboolean ok;

  if (p == NULL || path == NULL)
    return FALSE;
  proj_rebuild (p);
  r = lrg_reel_renderer_new (p->reel);
  ok = lrg_reel_renderer_render_still (r, frame, path, &err);
  g_object_unref (r);
  if (!ok && error_msg)
    *error_msg = g_strdup (err ? err->message : "still export failed");
  return ok;
}

void
cmacs_vidstudio_proj_set_export_quality (CmacsVidProject *p, int crf,
                                         int bitrate_kbps)
{
  if (p == NULL) return;
  p->export_crf = crf;           /* <0 keeps the exporter default */
  p->export_bitrate = bitrate_kbps;
}

/* ══════════════════════════════════════════════════════════════════════
 * Audio lane (mirrors the video-track descriptor/rebuild pattern)
 * ══════════════════════════════════════════════════════════════════════ */

/* Locate an audio seg by id. */
static VidAudioSeg *
find_audio (CmacsVidProject *p, gint id)
{
  guint i;
  if (p == NULL || p->audio == NULL)
    return NULL;
  for (i = 0; i < p->audio->len; i++)
    {
      VidAudioSeg *a = &g_array_index (p->audio, VidAudioSeg, i);
      if (a->id == (guint) id)
        return a;
    }
  return NULL;
}

/* Linear fade-in / fade-out applied by pre-scaling the sample buffer of a
   COPY (the engine's audio track has no fade envelope of its own). */
static LrgWaveData *
audio_with_fades (LrgWaveData *wave, double fade_in, double fade_out)
{
  LrgWaveData *w;
  gsize n = 0, i;
  gfloat *s;
  guint sr, ch;

  if (fade_in <= 0.0 && fade_out <= 0.0)
    return g_object_ref (wave);
  w = lrg_wave_data_copy (wave);
  sr = lrg_wave_data_get_sample_rate (w);
  ch = lrg_wave_data_get_channels (w);
  s = lrg_wave_data_get_samples (w, &n);
  if (s == NULL || n == 0 || sr == 0 || ch == 0)
    return w;
  {
    gsize fin = (gsize) (fade_in * sr) * ch;
    gsize fout = (gsize) (fade_out * sr) * ch;
    for (i = 0; i < fin && i < n; i++)
      s[i] *= (gfloat) ((double) (i / ch) / (double) (fin / ch ? fin / ch : 1));
    for (i = 0; i < fout && i < n; i++)
      {
        gsize idx = n - 1 - i;
        s[idx] *= (gfloat) ((double) (i / ch)
                            / (double) (fout / ch ? fout / ch : 1));
      }
  }
  lrg_wave_data_set_samples (w, s, n);
  return w;
}

/* (Re)build the mixed wave from the audio segs; cached until an edit. */
static LrgWaveData *
proj_mix_audio (CmacsVidProject *p)
{
  LrgReelAudioTrack *at;
  guint i;
  int total;
  g_autoptr (GError) err = NULL;

  if (p == NULL || p->audio == NULL || p->audio->len == 0)
    return NULL;
  if (!p->audio_dirty && p->mixed != NULL)
    return p->mixed;

  at = lrg_reel_audio_track_new (p->fps);
  for (i = 0; i < p->audio->len; i++)
    {
      VidAudioSeg *a = &g_array_index (p->audio, VidAudioSeg, i);
      if (a->wave != NULL)
        {
          LrgWaveData *w = audio_with_fades (a->wave, a->fade_in, a->fade_out);
          lrg_reel_audio_track_add (at, w, a->from_frame, a->volume,
                                    a->trim_start, a->trim_end);
          g_object_unref (w);
        }
      else if (a->source_path != NULL)
        {
          /* Fades on file segs would require loading here; add_from_file keeps
             the load inside the engine, so a fade is applied only to
             clip-extracted waves in v1 (documented). */
          lrg_reel_audio_track_add_from_file (at, a->source_path, a->from_frame,
                                              a->volume, a->trim_start,
                                              a->trim_end, NULL);
        }
    }
  total = cmacs_vidstudio_proj_total_frames (p);
  if (total < 1) total = 1;
  g_clear_object (&p->mixed);
  p->mixed = lrg_reel_audio_track_mix (at, p->audio_sample_rate,
                                       p->audio_channels, total, &err);
  p->audio_dirty = FALSE;
  g_object_unref (at);
  return p->mixed;
}

gint
cmacs_vidstudio_proj_add_audio_file (CmacsVidProject *p, const char *path,
                                     int from_frame, double volume,
                                     double trim_start, double trim_end,
                                     char **error_msg)
{
  VidAudioSeg a;
  if (p == NULL || path == NULL)
    { if (error_msg) *error_msg = g_strdup ("no project/path"); return -1; }
  memset (&a, 0, sizeof a);
  a.id = p->next_id++;
  a.source_path = g_strdup (path);
  a.wave = NULL;
  a.from_frame = from_frame;
  a.volume = (volume >= 0.0) ? volume : 1.0;
  a.trim_start = trim_start;
  a.trim_end = trim_end;
  {
    LrgWaveData *w = lrg_wave_data_new_from_file (path, NULL);
    if (w != NULL)
      { a.duration_secs = lrg_wave_data_get_duration (w);
        g_object_unref (w); }
  }
  g_array_append_val (p->audio, a);
  p->audio_dirty = TRUE;
  return (gint) a.id;
}

gint
cmacs_vidstudio_proj_add_audio_from_clip (CmacsVidProject *p, gint clip_id,
                                          int from_frame, double volume,
                                          char **error_msg)
{
  LrgReelClip *c = seg_clip (p, clip_id);
  LrgReelVideoSource *src;
  LrgWaveData *wave;
  VidAudioSeg a;
  g_autoptr (GError) err = NULL;

  if (c == NULL || !LRG_IS_REEL_VIDEO_CLIP (c))
    { if (error_msg) *error_msg = g_strdup ("clip is not a video clip");
      return -1; }
  src = lrg_reel_video_clip_get_source (LRG_REEL_VIDEO_CLIP (c));
  if (!lrg_reel_video_source_get_has_audio (src))
    { if (error_msg) *error_msg = g_strdup ("clip has no audio"); return -1; }
  wave = lrg_reel_video_source_extract_audio (src, &err);
  if (wave == NULL)
    { if (error_msg)
        *error_msg = g_strdup (err ? err->message : "extract failed");
      return -1; }
  memset (&a, 0, sizeof a);
  a.id = p->next_id++;
  /* Record the source video path so the extracted audio serialises: on load
     we re-extract from the same file (no clip-id remapping needed). */
  {
    VidTrack *vt; guint vsi;
    a.source_path = NULL;
    if (find_seg (p, clip_id, &vt, &vsi))
      {
        VidSeg *vs = &g_array_index (vt->segs, VidSeg, vsi);
        if (vs->asset)
          { a.source_path = g_strdup (vs->asset); a.extract = TRUE; }
      }
  }
  a.wave = wave;                 /* transfer full */
  a.from_frame = from_frame;
  a.volume = (volume >= 0.0) ? volume : 1.0;
  a.duration_secs = (wave != NULL) ? lrg_wave_data_get_duration (wave) : 0.0;
  g_array_append_val (p->audio, a);
  p->audio_dirty = TRUE;
  return (gint) a.id;
}

/* Extract audio directly from a video FILE (used on load to reproduce
   clip-extracted audio without needing the original clip). */
gint
cmacs_vidstudio_proj_add_audio_extract_file (CmacsVidProject *p,
                                             const char *video_path,
                                             int from_frame, double volume,
                                             char **error_msg)
{
  LrgReelVideoClip *clip;
  LrgReelVideoSource *src;
  LrgWaveData *wave;
  VidAudioSeg a;
  g_autoptr (GError) err = NULL;

  clip = lrg_reel_video_clip_new_from_file (video_path, &err);
  if (clip == NULL)
    { if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not load video");
      return -1; }
  src = lrg_reel_video_clip_get_source (clip);
  if (!lrg_reel_video_source_get_has_audio (src))
    { g_object_unref (clip);
      if (error_msg) *error_msg = g_strdup ("video has no audio");
      return -1; }
  wave = lrg_reel_video_source_extract_audio (src, &err);
  g_object_unref (clip);
  if (wave == NULL)
    { if (error_msg)
        *error_msg = g_strdup (err ? err->message : "extract failed");
      return -1; }
  memset (&a, 0, sizeof a);
  a.id = p->next_id++;
  a.source_path = g_strdup (video_path);
  a.extract = TRUE;
  a.wave = wave;
  a.from_frame = from_frame;
  a.volume = (volume >= 0.0) ? volume : 1.0;
  a.duration_secs = (wave != NULL) ? lrg_wave_data_get_duration (wave) : 0.0;
  g_array_append_val (p->audio, a);
  p->audio_dirty = TRUE;
  return (gint) a.id;
}

gboolean
cmacs_vidstudio_proj_set_audio_volume (CmacsVidProject *p, gint id, double v)
{
  VidAudioSeg *a = find_audio (p, id);
  if (a == NULL) return FALSE;
  a->volume = v;
  p->audio_dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_set_audio_fade (CmacsVidProject *p, gint id,
                                     double fade_in, double fade_out)
{
  VidAudioSeg *a = find_audio (p, id);
  if (a == NULL) return FALSE;
  a->fade_in = fade_in < 0.0 ? 0.0 : fade_in;
  a->fade_out = fade_out < 0.0 ? 0.0 : fade_out;
  p->audio_dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_remove_audio (CmacsVidProject *p, gint id)
{
  guint i;
  if (p == NULL || p->audio == NULL) return FALSE;
  for (i = 0; i < p->audio->len; i++)
    if (g_array_index (p->audio, VidAudioSeg, i).id == (guint) id)
      { g_array_remove_index (p->audio, i); p->audio_dirty = TRUE;
        return TRUE; }
  return FALSE;
}

guint
cmacs_vidstudio_proj_audio_count (CmacsVidProject *p)
{
  return (p && p->audio) ? p->audio->len : 0;
}

/* Details of the INDEXth audio clip on the lane (for the timeline/list).
   OUT_FRAMES is the on-timeline length in frames (trim-aware). */
gboolean
cmacs_vidstudio_proj_audio_at (CmacsVidProject *p, guint index, guint *out_id,
                               int *out_from, int *out_frames,
                               gboolean *out_extract)
{
  VidAudioSeg *a;
  double secs;

  if (p == NULL || p->audio == NULL || index >= p->audio->len)
    return FALSE;
  a = &g_array_index (p->audio, VidAudioSeg, index);
  if (out_id) *out_id = a->id;
  if (out_from) *out_from = a->from_frame;
  if (out_extract) *out_extract = a->extract;
  secs = a->duration_secs;
  if (a->trim_end > a->trim_start && a->trim_end > 0.0)
    secs = a->trim_end - a->trim_start;
  else if (a->trim_start > 0.0)
    secs = MAX (0.0, secs - a->trim_start);
  if (out_frames)
    *out_frames = (int) (secs * p->fps + 0.5);
  return TRUE;
}

void
cmacs_vidstudio_proj_set_export_preset (CmacsVidProject *p, const char *preset)
{
  if (p == NULL) return;
  g_free (p->export_preset);
  p->export_preset = (preset && preset[0]) ? g_strdup (preset) : NULL;
}

gboolean
cmacs_vidstudio_proj_export_audio (CmacsVidProject *p, const char *path,
                                   int format, char **error_msg)
{
  LrgReelAudioExporter *ax;
  LrgWaveData *w;
  g_autoptr (GError) err = NULL;
  gboolean ok;

  if (p == NULL || path == NULL) return FALSE;
  w = proj_mix_audio (p);
  if (w == NULL)
    { if (error_msg) *error_msg = g_strdup ("no audio to export"); return FALSE; }
  ax = lrg_reel_audio_exporter_new (path, (LrgReelAudioFormat) format);
  ok = lrg_reel_audio_exporter_export (ax, w, &err);
  if (!ok && error_msg)
    *error_msg = g_strdup (err ? err->message : "audio export failed");
  g_object_unref (ax);
  return ok;
}

/* ══════════════════════════════════════════════════════════════════════
 * Keyframing (per-clip, per-parameter; evaluated per rendered frame)
 *
 * The engine has no retained keyframe-track binding, so cmacs holds the
 * keyframes (clip-relative frame + value + easing) and a per-frame ANIMATOR
 * samples cached LrgKeyframeCurves and pushes values through the clip setters
 * (opacity / transform) or g_object_set (effect params) BEFORE the reel is
 * composited.  Curves are rebuilt only when a keyframe is added/cleared.
 * ══════════════════════════════════════════════════════════════════════ */

static gint
vidkey_cmp (gconstpointer a, gconstpointer b)
{
  double fa = ((const VidKey *) a)->frame, fb = ((const VidKey *) b)->frame;
  return (fa < fb) ? -1 : (fa > fb) ? 1 : 0;
}

/* Rebuild SEG's per-channel curves from its keys (only when dirty). */
static void
proj_seg_rebuild_curves (VidSeg *s)
{
  guint i, j;

  if (!s->keys_dirty)
    return;
  if (s->curves != NULL)
    g_ptr_array_set_size (s->curves, 0);
  else
    s->curves = g_ptr_array_new_with_free_func (vidcurve_free);
  if (s->keys != NULL)
    {
      g_array_sort (s->keys, vidkey_cmp);
      for (i = 0; i < s->keys->len; i++)
        {
          VidKey *k = &g_array_index (s->keys, VidKey, i);
          VidCurve *vc = NULL;
          for (j = 0; j < s->curves->len; j++)
            {
              VidCurve *c = g_ptr_array_index (s->curves, j);
              if (c->param == k->param && c->effect_index == k->effect_index
                  && g_strcmp0 (c->prop, k->prop) == 0)
                { vc = c; break; }
            }
          if (vc == NULL)
            {
              vc = g_new0 (VidCurve, 1);
              vc->param = k->param;
              vc->effect_index = k->effect_index;
              vc->prop = k->prop ? g_strdup (k->prop) : NULL;
              vc->curve = lrg_keyframe_curve_new ();
              g_ptr_array_add (s->curves, vc);
            }
          lrg_keyframe_curve_add_key (vc->curve, (gfloat) k->frame,
                                      (gfloat) k->value,
                                      (LrgEasingType) k->easing);
        }
    }
  s->keys_dirty = FALSE;
}

static void
proj_apply_effect_param (LrgReelClip *clip, int effect_index, const char *prop,
                         double value)
{
  LrgReelEffect *fx = lrg_reel_clip_get_effect (clip, (guint) effect_index);
  GParamSpec *ps;
  GValue gv = G_VALUE_INIT, dv = G_VALUE_INIT;

  if (fx == NULL || prop == NULL)
    return;
  ps = g_object_class_find_property (G_OBJECT_GET_CLASS (fx), prop);
  if (ps == NULL)
    return;
  g_value_init (&gv, G_PARAM_SPEC_VALUE_TYPE (ps));
  g_value_init (&dv, G_TYPE_DOUBLE);
  g_value_set_double (&dv, value);
  if (g_value_transform (&dv, &gv))
    g_object_set_property (G_OBJECT (fx), prop, &gv);
  g_value_unset (&gv);
  g_value_unset (&dv);
}

static void
proj_apply_animation (CmacsVidProject *p, int global_frame)
{
  guint ti, si, ci;

  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      for (si = 0; si < t->segs->len; si++)
        {
          VidSeg *s = &g_array_index (t->segs, VidSeg, si);
          double x = 0, y = 0, scale = 1, rot = 0;
          gboolean has_tf = FALSE;
          int seg_start, local;

          if (s->keys == NULL || s->keys->len == 0)
            continue;
          seg_start = cmacs_vidstudio_proj_clip_start_frame (p, (gint) s->id);
          local = global_frame - seg_start;
          if (local < 0 || local >= s->duration)
            continue;              /* clip not on screen this frame */
          proj_seg_rebuild_curves (s);
          for (ci = 0; ci < s->curves->len; ci++)
            {
              VidCurve *c = g_ptr_array_index (s->curves, ci);
              double v = lrg_keyframe_curve_sample (c->curve, (gfloat) local);
              switch (c->param)
                {
                case CMACS_VID_KF_OPACITY:
                  lrg_reel_clip_set_opacity (s->clip, v); break;
                case CMACS_VID_KF_X:        x = v; has_tf = TRUE; break;
                case CMACS_VID_KF_Y:        y = v; has_tf = TRUE; break;
                case CMACS_VID_KF_SCALE:    scale = v; has_tf = TRUE; break;
                case CMACS_VID_KF_ROTATION: rot = v; has_tf = TRUE; break;
                case CMACS_VID_KF_EFFECT_PARAM:
                  proj_apply_effect_param (s->clip, c->effect_index, c->prop, v);
                  break;
                default: break;
                }
            }
          if (has_tf)
            lrg_reel_clip_set_transform (s->clip, x, y, scale, scale, rot);
        }
    }
}

static gboolean
proj_has_keyframes (CmacsVidProject *p)
{
  guint ti, si;
  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      for (si = 0; si < t->segs->len; si++)
        {
          VidSeg *s = &g_array_index (t->segs, VidSeg, si);
          if (s->keys != NULL && s->keys->len > 0)
            return TRUE;
        }
    }
  return FALSE;
}

gboolean
cmacs_vidstudio_proj_add_keyframe (CmacsVidProject *p, gint clip_id, int param,
                                   int effect_index, const char *prop,
                                   double frame, double value, int easing)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;
  VidKey k;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  if (s->keys == NULL)
    {
      s->keys = g_array_new (FALSE, FALSE, sizeof (VidKey));
      g_array_set_clear_func (s->keys, vidkey_clear);
    }
  k.param = param;
  k.effect_index = effect_index;
  k.prop = (prop != NULL) ? g_strdup (prop) : NULL;
  k.frame = frame;
  k.value = value;
  k.easing = easing;
  g_array_append_val (s->keys, k);
  s->keys_dirty = TRUE;
  /* Do NOT set p->dirty: keyframes do not change the timeline structure; they
     are applied per rendered frame by proj_apply_animation. */
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_clear_keyframes (CmacsVidProject *p, gint clip_id,
                                      int param)
{
  VidTrack *t = NULL;
  guint si = 0, i;
  VidSeg *s;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  if (s->keys == NULL)
    return TRUE;
  if (param < 0)
    g_array_set_size (s->keys, 0);
  else
    for (i = s->keys->len; i > 0; i--)
      if (g_array_index (s->keys, VidKey, i - 1).param == param)
        g_array_remove_index (s->keys, i - 1);
  s->keys_dirty = TRUE;
  return TRUE;
}

gint
cmacs_vidstudio_proj_keyframe_count (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t = NULL;
  guint si = 0;
  if (!find_seg (p, clip_id, &t, &si))
    return -1;
  {
    VidSeg *s = &g_array_index (t->segs, VidSeg, si);
    return s->keys ? (gint) s->keys->len : 0;
  }
}

/* Map an effect object back to a CMACS_VID_FX_* code, or -1. */
static int
effect_type_code (LrgReelEffect *fx)
{
  GType t = G_OBJECT_TYPE (fx);
  if (t == LRG_TYPE_REEL_BLUR_EFFECT)        return CMACS_VID_FX_BLUR;
  if (t == LRG_TYPE_REEL_BLOOM_EFFECT)       return CMACS_VID_FX_BLOOM;
  if (t == LRG_TYPE_REEL_COLOR_GRADE_EFFECT) return CMACS_VID_FX_COLOR_GRADE;
  if (t == LRG_TYPE_REEL_VIGNETTE_EFFECT)    return CMACS_VID_FX_VIGNETTE;
  if (t == LRG_TYPE_REEL_GRAIN_EFFECT)       return CMACS_VID_FX_GRAIN;
  return -1;
}

/* Append " (effects (CODE (prop val)...) ...)" for a clip's effect chain. */
static void
serialize_effects (GString *o, LrgReelClip *clip)
{
  guint ne = lrg_reel_clip_get_n_effects (clip), ei, pi, np;
  gboolean opened = FALSE;

  for (ei = 0; ei < ne; ei++)
    {
      LrgReelEffect *fx = lrg_reel_clip_get_effect (clip, ei);
      int code = fx ? effect_type_code (fx) : -1;
      GParamSpec **specs;
      if (code < 0)
        continue;
      if (!opened) { g_string_append (o, " (effects"); opened = TRUE; }
      g_string_append_printf (o, " (%d", code);
      specs = g_object_class_list_properties (G_OBJECT_GET_CLASS (fx), &np);
      for (pi = 0; pi < np; pi++)
        {
          GParamSpec *ps = specs[pi];
          GType vt = G_PARAM_SPEC_VALUE_TYPE (ps);
          if (!(ps->flags & G_PARAM_READABLE) || !(ps->flags & G_PARAM_WRITABLE))
            continue;
          if (vt == G_TYPE_INT || vt == G_TYPE_UINT || vt == G_TYPE_FLOAT
              || vt == G_TYPE_DOUBLE)
            {
              GValue gv = G_VALUE_INIT, dv = G_VALUE_INIT;
              g_value_init (&gv, vt);
              g_value_init (&dv, G_TYPE_DOUBLE);
              g_object_get_property (G_OBJECT (fx),
                                     g_param_spec_get_name (ps), &gv);
              if (g_value_transform (&gv, &dv))
                g_string_append_printf (o, " (%s %g)",
                                        g_param_spec_get_name (ps),
                                        g_value_get_double (&dv));
              g_value_unset (&gv);
              g_value_unset (&dv);
            }
        }
      g_free (specs);
      g_string_append_c (o, ')');
    }
  if (opened)
    g_string_append_c (o, ')');
}

/* ── Serialization (a versioned, Lisp-readable S-expression) ─────────────
   The Elisp side replays this by calling the add-* DEFUNs, so only the
   creation descriptors + post-creation setters need to be emitted. */
char *
cmacs_vidstudio_proj_serialize (CmacsVidProject *p)
{
  GString *o;
  guint ti, si, ki;

  if (p == NULL)
    return NULL;
  o = g_string_new (NULL);
  g_string_append (o, "(vstudio (version 1)");
  g_string_append_printf (o, " (width %d) (height %d) (fps %g)",
                          p->width, p->height, p->fps);
  g_string_append (o, "\n (tracks");
  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      g_string_append (o, "\n  (track");
      for (si = 0; si < t->segs->len; si++)
        {
          VidSeg *s = &g_array_index (t->segs, VidSeg, si);
          g_string_append_printf (o, "\n   (clip (kind %d) (id %u) (dur %d)",
                                  s->kind, s->id, s->duration);
          if (s->asset != NULL)
            {
              char *esc = g_strescape (s->asset, NULL);
              g_string_append_printf (o, " (asset \"%s\")", esc);
              g_free (esc);
            }
          g_string_append_printf (o, " (color %u %u %u %u)",
                                  s->col[0], s->col[1], s->col[2], s->col[3]);
          if (s->kind == CMACS_VID_KIND_VIDEO)
            g_string_append_printf (o, " (in %g) (out %g)",
                                    s->in_sec, s->out_sec);
          if (s->trans_type >= 0)
            g_string_append_printf (o,
                " (transition %d %d %d)", s->trans_type, s->trans_overlap,
                s->trans_easing);
          g_string_append_printf (o, " (opacity %g) (blend %d)",
                                  lrg_reel_clip_get_opacity (s->clip),
                                  (int) lrg_reel_clip_get_blend_mode (s->clip));
          {
          {
            gint bx, by, bw, bh;
            gboolean has_box = FALSE;
            if (LRG_IS_REEL_VIDEO_CLIP (s->clip))
              has_box = lrg_reel_video_clip_get_box
                          (LRG_REEL_VIDEO_CLIP (s->clip), &bx, &by, &bw, &bh);
            else if (LRG_IS_REEL_IMAGE_CLIP (s->clip))
              has_box = lrg_reel_image_clip_get_box
                          (LRG_REEL_IMAGE_CLIP (s->clip), &bx, &by, &bw, &bh);
            if (has_box)
              g_string_append_printf (o, " (box %d %d %d %d)", bx, by, bw, bh);
          }
            double tx = lrg_reel_clip_get_x (s->clip);
            double ty = lrg_reel_clip_get_y (s->clip);
            double tsx = lrg_reel_clip_get_scale_x (s->clip);
            double tsy = lrg_reel_clip_get_scale_y (s->clip);
            double trot = lrg_reel_clip_get_rotation (s->clip);
            if (tx != 0.0 || ty != 0.0 || tsx != 1.0 || tsy != 1.0
                || trot != 0.0)
              g_string_append_printf (o, " (transform %g %g %g %g %g)",
                                      tx, ty, tsx, tsy, trot);
          }
          serialize_effects (o, s->clip);
          if (s->keys != NULL && s->keys->len > 0)
            {
              g_string_append (o, " (keyframes");
              for (ki = 0; ki < s->keys->len; ki++)
                {
                  VidKey *k = &g_array_index (s->keys, VidKey, ki);
                  g_string_append_printf (o, " (%d %d %g %g %d", k->param,
                                          k->effect_index, k->frame, k->value,
                                          k->easing);
                  if (k->prop != NULL)
                    {
                      char *e = g_strescape (k->prop, NULL);
                      g_string_append_printf (o, " \"%s\"", e);
                      g_free (e);
                    }
                  g_string_append_c (o, ')');
                }
              g_string_append_c (o, ')');
            }
          g_string_append_c (o, ')');    /* clip */
        }
      g_string_append_c (o, ')');        /* track */
    }
  g_string_append (o, ")");              /* tracks */
  g_string_append (o, "\n (audio");
  for (si = 0; si < p->audio->len; si++)
    {
      VidAudioSeg *a = &g_array_index (p->audio, VidAudioSeg, si);
      if (a->source_path == NULL)
        continue;   /* an in-memory wave with no reproducible source */
      {
        char *e = g_strescape (a->source_path, NULL);
        g_string_append_printf (o,
            "\n  (seg (source \"%s\")%s (from %d) (volume %g)"
            " (trim-start %g) (trim-end %g) (fade-in %g) (fade-out %g))",
            e, a->extract ? " (extract t)" : "", a->from_frame, a->volume,
            a->trim_start, a->trim_end, a->fade_in, a->fade_out);
        g_free (e);
      }
    }
  g_string_append (o, "))");             /* audio + vstudio */
  return g_string_free (o, FALSE);
}

/* Feed the renderer through EX.  When keyframes exist the animator must run
   per frame, so cmacs drives the begin/add_frame/finish loop; otherwise the
   engine's own loop is used (keeping motion-blur / parallel rendering). */
static gboolean
proj_has_video (CmacsVidProject *p)
{
  guint ti, si;
  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      for (si = 0; si < t->segs->len; si++)
        if (LRG_IS_REEL_VIDEO_CLIP (g_array_index (t->segs, VidSeg, si).clip))
          return TRUE;
    }
  return FALSE;
}

static gboolean
proj_render_to_exporter (CmacsVidProject *p, LrgReelRenderer *r,
                         LrgReelExporter *ex, GError **error)
{
  int total, f;

  /* Parallelise the render across all cores when it is safe -- i.e. no
     keyframe animation (frames are independent) AND no video clips (their
     source frame-cache is not thread-safe; see render_parallel's contract). */
  if (!proj_has_keyframes (p))
    {
      if (proj_has_video (p))
        return lrg_reel_renderer_render_to_exporter (r, ex, error);
      return lrg_reel_renderer_render_parallel (r, 0, ex, error);
    }

  total = cmacs_vidstudio_proj_total_frames (p);
  if (total < 1) total = 1;
  if (!lrg_reel_exporter_begin (ex, p->width, p->height, p->fps, error))
    return FALSE;
  for (f = 0; f < total; f++)
    {
      GrlImage *img;
      proj_apply_animation (p, f);
      img = lrg_reel_renderer_get_canvas_image (r, f);   /* transfer none */
      if (img == NULL || !lrg_reel_exporter_add_frame (ex, img, error))
        return FALSE;
    }
  return lrg_reel_exporter_finish (ex, error);
}

gboolean
cmacs_vidstudio_proj_set_clip_duration (CmacsVidProject *p, gint clip_id,
                                        int frames)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;

  if (frames <= 0 || !find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  s->duration = frames;
  lrg_reel_clip_set_duration_in_frames (s->clip, frames);
  p->dirty = TRUE;
  return TRUE;
}

/* Change the source in/out slice of a VIDEO clip after import (the "original
   included time lengths/offsets"): resolve in/out against the source duration
   exactly like import, update the engine trim + the descriptor, and recompute
   the on-timeline length from the slice.  Non-video clips have no source
   slice, so this is a no-op returning FALSE. */
gboolean
cmacs_vidstudio_proj_set_clip_trim (CmacsVidProject *p, gint clip_id,
                                    double in_sec, double out_sec)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;
  LrgReelVideoClip *vc;
  LrgReelVideoSource *src;
  double src_dur, in, out;
  int frames;

  if (p == NULL || !find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  if (!LRG_IS_REEL_VIDEO_CLIP (s->clip))
    return FALSE;
  vc = LRG_REEL_VIDEO_CLIP (s->clip);
  src = lrg_reel_video_clip_get_source (vc);
  src_dur = lrg_reel_video_source_get_duration (src);
  in  = (in_sec < 0.0) ? 0.0 : in_sec;
  out = (out_sec <= 0.0 || (src_dur > 0.0 && out_sec > src_dur))
          ? src_dur : out_sec;
  if (src_dur > 0.0 && out <= in)
    out = src_dur;
  lrg_reel_video_clip_set_trim_start (vc, in);
  lrg_reel_video_clip_set_trim_end (vc, out);
  s->in_sec = in;
  s->out_sec = out;
  frames = (int) ((out - in) * p->fps + 0.5);
  if (frames < 1)
    frames = 1;
  s->duration = frames;
  lrg_reel_clip_set_duration_in_frames (s->clip, frames);
  p->dirty = TRUE;
  return TRUE;
}

/* Read a VIDEO clip's current slice: in/out points (seconds) + the source's
   full duration (for prompting sensible defaults/bounds). */
gboolean
cmacs_vidstudio_proj_clip_slice (CmacsVidProject *p, gint clip_id,
                                 double *in_sec, double *out_sec,
                                 double *src_dur)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;

  if (p == NULL || !find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  if (!LRG_IS_REEL_VIDEO_CLIP (s->clip))
    return FALSE;
  if (in_sec) *in_sec = s->in_sec;
  if (out_sec) *out_sec = s->out_sec;
  if (src_dur)
    *src_dur = lrg_reel_video_source_get_duration
                 (lrg_reel_video_clip_get_source (LRG_REEL_VIDEO_CLIP (s->clip)));
  return TRUE;
}

/* Resolve a whole-video clip's on-timeline length from its real decoded frame
   count.  Import derives the length from ffprobe (get_duration); when ffprobe
   is unavailable or cannot probe the container, that is 0 and the clip lands
   as a 1-frame placeholder.  Once the source has decoded (get_frame_count is
   then exact) this recomputes the length.  Only clips whose trim_end was left
   at/behind the in-point (i.e. "whole video / to end", length unknown) are
   touched; explicitly sliced clips keep their slice.  Returns TRUE if the
   duration changed. */
gboolean
cmacs_vidstudio_proj_refresh_video_duration (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;
  LrgReelVideoClip *vc;
  LrgReelVideoSource *src;
  gdouble in, cur_end, sfps, dur_total;
  gint fc, frames;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  s = &g_array_index (t->segs, VidSeg, si);
  if (!LRG_IS_REEL_VIDEO_CLIP (s->clip))
    return FALSE;
  vc = LRG_REEL_VIDEO_CLIP (s->clip);
  src = lrg_reel_video_clip_get_source (vc);
  in = lrg_reel_video_clip_get_trim_start (vc);
  cur_end = lrg_reel_video_clip_get_trim_end (vc);
  if (cur_end > in + 1e-6)
    return FALSE;                      /* explicitly sliced -> leave it */
  fc = lrg_reel_video_source_get_frame_count (src);
  if (fc < 2)
    return FALSE;                      /* not decoded yet (async estimate) */
  sfps = lrg_reel_video_source_get_fps (src);
  dur_total = (sfps > 0.0) ? (gdouble) fc / sfps : (gdouble) fc / p->fps;
  if (dur_total <= in)
    return FALSE;
  lrg_reel_video_clip_set_trim_end (vc, dur_total);
  frames = (int) ((dur_total - in) * p->fps + 0.5);
  if (frames < 1)
    frames = 1;
  if (frames == s->duration)
    return FALSE;
  return cmacs_vidstudio_proj_set_clip_duration (p, clip_id, frames);
}

/* Refresh every video clip's whole-video duration; returns TRUE if any changed. */
gboolean
cmacs_vidstudio_proj_refresh_all_video_durations (CmacsVidProject *p)
{
  guint ti, si;
  gboolean any = FALSE;

  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      for (si = 0; si < t->segs->len; si++)
        {
          VidSeg *s = &g_array_index (t->segs, VidSeg, si);
          if (cmacs_vidstudio_proj_refresh_video_duration (p, (gint) s->id))
            any = TRUE;
        }
    }
  return any;
}

gint
cmacs_vidstudio_proj_split_clip (CmacsVidProject *p, gint clip_id, int at_frame)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;
  VidSeg tail;

  if (!find_seg (p, clip_id, &t, &si))
    return -1;
  s = &g_array_index (t->segs, VidSeg, si);
  if (at_frame <= 0 || at_frame >= s->duration)
    return -1;

  /* Tail shares the same source clip (a fresh ref); v1 does not re-trim the
     source, so the tail replays from the clip's own start. */
  memset (&tail, 0, sizeof tail);
  tail.id = p->next_id++;
  tail.clip = g_object_ref (s->clip);
  tail.trans = NULL;
  tail.duration = s->duration - at_frame;
  tail.trans_overlap = 0;
  tail.trans_type = -1;
  tail.kind = s->kind;
  tail.asset = s->asset ? g_strdup (s->asset) : NULL;
  memcpy (tail.col, s->col, sizeof tail.col);
  tail.in_sec = s->in_sec;
  tail.out_sec = s->out_sec;

  s->duration = at_frame;
  lrg_reel_clip_set_duration_in_frames (s->clip, at_frame);

  g_array_insert_val (t->segs, si + 1, tail);
  p->dirty = TRUE;
  return (gint) tail.id;  /* NB: pointer s may be invalid after insert */
}

gboolean
cmacs_vidstudio_proj_move_clip (CmacsVidProject *p, gint clip_id,
                                guint new_track, guint new_index)
{
  VidTrack *t = NULL, *dst;
  guint si = 0;
  VidSeg copy;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  dst = track_at (p, new_track);
  if (dst == NULL)
    return FALSE;

  /* Move the segment to DST.  Take an extra ref on the owned objects BEFORE
     the remove (whose clear-func unrefs once), so `copy' keeps exactly one
     ref to hand to the destination slot. */
  copy = g_array_index (t->segs, VidSeg, si);
  g_object_ref (copy.clip);
  if (copy.trans)
    g_object_ref (copy.trans);
  g_array_remove_index (t->segs, si);

  if (new_index > dst->segs->len)
    new_index = dst->segs->len;
  g_array_insert_val (dst->segs, new_index, copy);
  p->dirty = TRUE;
  return TRUE;
}

gboolean
cmacs_vidstudio_proj_remove_clip (CmacsVidProject *p, gint clip_id,
                                  gboolean ripple)
{
  VidTrack *t = NULL;
  guint si = 0;
  VidSeg *s;

  if (!find_seg (p, clip_id, &t, &si))
    return FALSE;
  if (!ripple)
    {
      /* Replace with a transparent gap of equal duration. */
      GrlColor clear = { 0, 0, 0, 0 };
      s = &g_array_index (t->segs, VidSeg, si);
      g_clear_object (&s->trans);
      g_clear_object (&s->clip);
      s->clip = LRG_REEL_CLIP (lrg_reel_solid_clip_new (&clear));
      lrg_reel_clip_set_duration_in_frames (s->clip, s->duration);
      s->trans_overlap = 0;
    }
  else
    {
      g_array_remove_index (t->segs, si);
    }
  p->dirty = TRUE;
  return TRUE;
}

gint
cmacs_vidstudio_proj_clip_at (CmacsVidProject *p, guint track, guint index)
{
  VidTrack *t = track_at (p, track);
  if (t == NULL || index >= t->segs->len)
    return -1;
  return (gint) g_array_index (t->segs, VidSeg, index).id;
}

gint
cmacs_vidstudio_proj_clip_duration (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t = NULL;
  guint si = 0;
  if (!find_seg (p, clip_id, &t, &si))
    return -1;
  return g_array_index (t->segs, VidSeg, si).duration;
}

gint
cmacs_vidstudio_proj_clip_start_frame (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t = NULL;
  guint si = 0, i;
  int start = 0;

  if (!find_seg (p, clip_id, &t, &si))
    return -1;
  for (i = 0; i < si; i++)
    {
      VidSeg *s = &g_array_index (t->segs, VidSeg, i);
      VidSeg *next = &g_array_index (t->segs, VidSeg, i + 1);
      start += s->duration;
      if (next->trans != NULL)
        start -= next->trans_overlap;
    }
  return start;
}

/* Rebuild p->reel from the track/segment model. */
static void
proj_rebuild (CmacsVidProject *p)
{
  int total;
  guint ti;

  if (!p->dirty && p->reel != NULL)
    return;

  total = cmacs_vidstudio_proj_total_frames (p);
  if (total < 1)
    total = 1;

  g_clear_object (&p->reel);
  p->reel = lrg_reel_new ("vidstudio", p->width, p->height, p->fps, total);

  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);
      LrgReelTransitionSeries *series;
      guint i;

      if (t->segs->len == 0)
        continue;
      series = lrg_reel_transition_series_new ();
      for (i = 0; i < t->segs->len; i++)
        {
          VidSeg *s = &g_array_index (t->segs, VidSeg, i);
          if (i > 0 && s->trans != NULL)
            lrg_reel_transition_series_add_transition (series, s->trans,
                                                       s->trans_overlap);
          lrg_reel_transition_series_add (series, s->clip, s->duration);
        }
      lrg_reel_add_clip (p->reel, LRG_REEL_CLIP (series));
      g_object_unref (series);  /* the reel holds its own ref */
    }
  p->dirty = FALSE;
}

guint8 *
cmacs_vidstudio_proj_render_png (CmacsVidProject *p, int frame, gsize *out_n)
{
  LrgReelRenderer *r;
  GrlImage *img;
  guint8 *bytes = NULL;

  if (out_n)
    *out_n = 0;
  if (p == NULL)
    return NULL;
  proj_rebuild (p);
  r = lrg_reel_renderer_new (p->reel);
  proj_apply_animation (p, frame);
  img = lrg_reel_renderer_get_canvas_image (r, frame);
  if (img != NULL)
    bytes = grl_image_export_to_memory (img, ".png", out_n);
  g_object_unref (r);
  return bytes;
}

/* Render FRAME and return an OWNED GrlImage copy (transfer full) for the live
 * viewport (get_canvas_image is transfer-none / reused, so copy it).  Returned
 * as void* to keep the DEFUN layer raylib-free. */
void *
cmacs_vidstudio_proj_canvas_image (CmacsVidProject *p, int frame)
{
  LrgReelRenderer *r;
  GrlImage *img, *copy = NULL;

  if (p == NULL)
    return NULL;
  proj_rebuild (p);
  r = lrg_reel_renderer_new (p->reel);
  proj_apply_animation (p, frame);
  img = lrg_reel_renderer_get_canvas_image (r, frame);
  if (img != NULL)
    copy = grl_image_copy (img);
  g_object_unref (r);
  return copy;
}

guint8 *
cmacs_vidstudio_proj_render_ppm (CmacsVidProject *p, int frame, int max_w,
                                 gsize *out_n)
{
  LrgReelRenderer *r;
  GrlImage *img;
  GrlImage *scaled = NULL;
  const guint8 *px;
  guint8 *out = NULL;
  gsize npx = 0;
  int w, h, hdr;
  gsize i, n;
  char header[64];

  if (out_n)
    *out_n = 0;
  if (p == NULL)
    return NULL;
  proj_rebuild (p);
  r = lrg_reel_renderer_new (p->reel);
  proj_apply_animation (p, frame);
  img = lrg_reel_renderer_get_canvas_image (r, frame);
  if (img == NULL)
    {
      g_object_unref (r);
      return NULL;
    }
  w = p->width;
  h = p->height;
  if (max_w > 0 && w > max_w)
    {
      /* Downscale before encoding: preview cost scales with pixels. */
      int sh = MAX (1, (int) ((double) h * max_w / w + 0.5));

      scaled = grl_image_resized (img, max_w, sh);
      if (scaled != NULL)
        {
          img = scaled;
          w = max_w;
          h = sh;
        }
    }
  px = grl_image_get_pixels (img, &npx);
  if (px != NULL && npx >= (gsize) w * h * 4)
    {
      /* Binary PPM (P6): trivial header + packed RGB.  No compression, so
         encoding is a straight copy and Emacs's native pbm loader decodes
         it far faster than PNG — the point of this preview-only path. */
      guint8 *dst;

      hdr = g_snprintf (header, sizeof header, "P6\n%d %d\n255\n", w, h);
      n = (gsize) hdr + (gsize) w * h * 3;
      out = g_malloc (n);
      memcpy (out, header, (gsize) hdr);
      dst = out + hdr;
      for (i = 0; i < (gsize) w * h; i++)
        {
          dst[0] = px[i * 4 + 0];
          dst[1] = px[i * 4 + 1];
          dst[2] = px[i * 4 + 2];
          dst += 3;
        }
      if (out_n)
        *out_n = n;
    }
  g_clear_object (&scaled);
  g_object_unref (r);
  return out;
}

gboolean
cmacs_vidstudio_proj_frame_pixel (CmacsVidProject *p, int frame, int x, int y,
                                  guint8 *r, guint8 *g, guint8 *b, guint8 *a)
{
  LrgReelRenderer *rr;
  GrlImage *img;
  const guint8 *px;
  gsize n = 0;
  gsize idx;
  gboolean ok = FALSE;

  if (p == NULL || x < 0 || y < 0 || x >= p->width || y >= p->height)
    return FALSE;
  proj_rebuild (p);
  rr = lrg_reel_renderer_new (p->reel);
  proj_apply_animation (p, frame);
  img = lrg_reel_renderer_get_canvas_image (rr, frame);
  if (img != NULL)
    {
      px = grl_image_get_pixels (img, &n);
      idx = ((gsize) y * p->width + x) * 4;
      if (px != NULL && idx + 3 < n)
        {
          if (r) *r = px[idx + 0];
          if (g) *g = px[idx + 1];
          if (b) *b = px[idx + 2];
          if (a) *a = px[idx + 3];
          ok = TRUE;
        }
    }
  g_object_unref (rr);
  return ok;
}

gboolean
cmacs_vidstudio_proj_clip_ready (CmacsVidProject *p, gint clip_id)
{
  VidTrack *t;
  guint si;
  LrgReelClip *clip;

  if (p == NULL || !find_seg (p, clip_id, &t, &si))
    return TRUE;                /* unknown id: nothing to wait for */
  clip = g_array_index (t->segs, VidSeg, si).clip;
  if (LRG_IS_REEL_VIDEO_CLIP (clip))
    return lrg_reel_video_source_is_decoded
      (lrg_reel_video_clip_get_source (LRG_REEL_VIDEO_CLIP (clip)));
  return TRUE;
}

/* Block until every video clip has real frames (export correctness: the
   async preview path substitutes placeholders while decoding). */
static void
proj_wait_video_clips (CmacsVidProject *p)
{
  guint ti;
  guint si;

  for (ti = 0; ti < p->tracks->len; ti++)
    {
      VidTrack *t = g_ptr_array_index (p->tracks, ti);

      for (si = 0; si < t->segs->len; si++)
        {
          LrgReelClip *clip = g_array_index (t->segs, VidSeg, si).clip;

          if (LRG_IS_REEL_VIDEO_CLIP (clip))
            lrg_reel_video_source_wait_decoded
              (lrg_reel_video_clip_get_source (LRG_REEL_VIDEO_CLIP (clip)),
               NULL);
        }
    }
  /* Sources are decoded now, so any whole-video clip whose length ffprobe
     could not determine at import can be resolved from the real frame count
     -- export/scripted callers get the full timeline without a UI poll. */
  cmacs_vidstudio_proj_refresh_all_video_durations (p);
}

gboolean
cmacs_vidstudio_proj_export_video (CmacsVidProject *p, const char *path,
                                   int codec, char **error_msg)
{
  LrgReelRenderer *r;
  LrgReelVideoExporter *ex;
  LrgReelVideoCodec c;
  g_autoptr (GError) err = NULL;
  gboolean ok;

  if (p == NULL || path == NULL)
    return FALSE;
  switch (codec)
    {
    case 1:  c = LRG_REEL_VIDEO_CODEC_VP9; break;
    case 2:  c = LRG_REEL_VIDEO_CODEC_H265; break;
    case 3:  c = LRG_REEL_VIDEO_CODEC_PRORES; break;
    case 4:  c = LRG_REEL_VIDEO_CODEC_AV1; break;
    default: c = LRG_REEL_VIDEO_CODEC_H264; break;
    }
  proj_wait_video_clips (p);
  proj_rebuild (p);
  r = lrg_reel_renderer_new (p->reel);
  ex = lrg_reel_video_exporter_new (path, c);
  if (p->export_preset != NULL)
    lrg_reel_video_exporter_set_preset (ex, p->export_preset);
  lrg_reel_video_exporter_set_show_progress (ex, TRUE);  /* stderr stats */
  if (p->export_crf >= 0)
    lrg_reel_video_exporter_set_crf (ex, p->export_crf);
  if (p->export_bitrate > 0)
    lrg_reel_video_exporter_set_bitrate (ex, p->export_bitrate);
  /* Mux the mixed audio lane into the video, if any. */
  if (p->audio != NULL && p->audio->len > 0)
    {
      LrgWaveData *w = proj_mix_audio (p);
      if (w != NULL)
        lrg_reel_video_exporter_set_audio (ex, w);
    }
  ok = proj_render_to_exporter (p, r, LRG_REEL_EXPORTER (ex), &err);
  if (!ok && error_msg)
    *error_msg = g_strdup (err ? err->message : "export failed");
  g_object_unref (ex);
  g_object_unref (r);
  return ok;
}

gboolean
cmacs_vidstudio_proj_export_gif (CmacsVidProject *p, const char *path,
                                 char **error_msg)
{
  LrgReelRenderer *r;
  LrgReelGifExporter *ex;
  g_autoptr (GError) err = NULL;
  gboolean ok;

  if (p == NULL || path == NULL)
    return FALSE;
  ex = lrg_reel_gif_exporter_new (path, &err);
  if (ex == NULL)
    {
      if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not open GIF");
      return FALSE;
    }
  proj_wait_video_clips (p);
  proj_rebuild (p);
  r = lrg_reel_renderer_new (p->reel);
  ok = proj_render_to_exporter (p, r, LRG_REEL_EXPORTER (ex), &err);
  if (!ok && error_msg)
    *error_msg = g_strdup (err ? err->message : "export failed");
  g_object_unref (ex);
  g_object_unref (r);
  return ok;
}

#endif /* HAVE_CMACS_VIDSTUDIO */
