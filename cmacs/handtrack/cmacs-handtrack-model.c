/* Camera hand tracking for CMacs -- the pipeline's arithmetic.

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later

MediaPipe's hand pipeline, minus the networks (which run through
onnxruntime, cmacs-handtrack-ort.c):

  1. palm detection on the whole frame, letterboxed to 192 x 192: an SSD
     over 2016 anchors, each with a box and seven palm keypoints;
  2. a rotated square region of interest per palm, turned so the
     fingers point up and enlarged 2.6x to hold the whole hand;
  3. hand landmarks on that region, cropped to 224 x 224: 21 points;
  4. on the next frame, regions come from those landmarks instead, and
     the detector runs again only when a hand is lost.

All of this is plain float arithmetic on images and tensors, so it is
tested with synthetic ones (test/cmacs/cmacs-handtrack-tests.el).  The
constants are MediaPipe's palm_detection / hand_landmark graph options
(ssd_anchors_calculator, rect_transformation), which the ONNX
conversions keep.  */

#include <config.h>

#ifdef HAVE_CMACS_HANDTRACK

#include <math.h>
#include <string.h>

#include "cmacs-handtrack.h"

/* ----------------------------------------------------------- anchors -- */

/* MediaPipe's palm SSD at 192: strides 8, 16, 16, 16; consecutive layers
   with one stride share a feature map, so stride 8 gives 24 x 24 cells
   of 2 anchors and the three stride-16 layers 12 x 12 cells of 6; every
   anchor is centred in its cell and fixed-size.  XY gets 2 floats per
   anchor (normalised centre).  Returns the count, CMACS_HT_ANCHORS.  */
int
cmacs_ht_anchors (float *xy)
{
  static const struct { int stride, per_cell; } layers[] = {
    { 8, 2 }, { 16, 6 }
  };
  int n = 0;
  size_t l;

  for (l = 0; l < G_N_ELEMENTS (layers); l++)
    {
      int cells = CMACS_HT_PALM_SIZE / layers[l].stride;
      int x, y, k;

      for (y = 0; y < cells; y++)
        for (x = 0; x < cells; x++)
          for (k = 0; k < layers[l].per_cell; k++)
            {
              if (xy != NULL)
                {
                  xy[2 * n] = ((float) x + 0.5f) / (float) cells;
                  xy[2 * n + 1] = ((float) y + 0.5f) / (float) cells;
                }
              n++;
            }
    }
  return n;
}

/* ----------------------------------------------------------- sampling -- */

/* Bilinear sample of channel C at (X, Y) in pixel centres; 0 outside.
   MIRROR reads the image flipped left to right.  */
static float
sample (const guint8 *rgb, int w, int h, int stride, bool mirror, float x,
        float y, int c)
{
  int x0, y0, x1, y1;
  float fx, fy, a, b, cc, d;

  if (mirror)
    x = (float) (w - 1) - x;
  if (x < -0.5f || y < -0.5f || x > (float) w - 0.5f || y > (float) h - 0.5f)
    return 0.0f;
  x0 = (int) floorf (x);
  y0 = (int) floorf (y);
  fx = x - (float) x0;
  fy = y - (float) y0;
  x1 = CLAMP (x0 + 1, 0, w - 1);
  y1 = CLAMP (y0 + 1, 0, h - 1);
  x0 = CLAMP (x0, 0, w - 1);
  y0 = CLAMP (y0, 0, h - 1);
  a = rgb[y0 * stride + x0 * 3 + c];
  b = rgb[y0 * stride + x1 * 3 + c];
  cc = rgb[y1 * stride + x0 * 3 + c];
  d = rgb[y1 * stride + x1 * 3 + c];
  return ((a * (1.0f - fx) + b * fx) * (1.0f - fy)
          + (cc * (1.0f - fx) + d * fx) * fy) / 255.0f;
}

static void
store (float *out, int size, bool nchw, int x, int y, int c, float v)
{
  if (nchw)
    out[(size_t) c * (size_t) size * (size_t) size + (size_t) y * (size_t) size
        + (size_t) x] = v;
  else
    out[((size_t) y * (size_t) size + (size_t) x) * 3 + (size_t) c] = v;
}

/* Fit the frame into a SIZE square, centred, keeping its aspect (the
   bands are 0): the palm detector's input, in 0..1.  *SCALE, *PADX and
   *PADY map a letterboxed pixel back: image = (lb - pad) / scale.  */
void
cmacs_ht_letterbox (const guint8 *rgb, int w, int h, int stride, bool mirror,
                    int size, bool nchw, float *out, float *scale,
                    float *padx, float *pady)
{
  float s = (float) size / (float) MAX (w, h);
  float px = ((float) size - (float) w * s) / 2.0f;
  float py = ((float) size - (float) h * s) / 2.0f;
  int x, y, c;

  for (y = 0; y < size; y++)
    for (x = 0; x < size; x++)
      {
        float sx = ((float) x + 0.5f - px) / s - 0.5f;
        float sy = ((float) y + 0.5f - py) / s - 0.5f;
        for (c = 0; c < 3; c++)
          store (out, size, nchw, x, y, c,
                 sample (rgb, w, h, stride, mirror, sx, sy, c));
      }
  *scale = s;
  *padx = px;
  *pady = py;
}

/* -------------------------------------------------------- palm decode -- */

static float
sigmoid (float v)
{
  v = CLAMP (v, -100.0f, 100.0f);
  return 1.0f / (1.0f + expf (-v));
}

static float
iou (const CmacsHtPalm *a, const CmacsHtPalm *b)
{
  float ax0 = a->cx - a->w / 2, ax1 = a->cx + a->w / 2;
  float ay0 = a->cy - a->h / 2, ay1 = a->cy + a->h / 2;
  float bx0 = b->cx - b->w / 2, bx1 = b->cx + b->w / 2;
  float by0 = b->cy - b->h / 2, by1 = b->cy + b->h / 2;
  float iw = MIN (ax1, bx1) - MAX (ax0, bx0);
  float ih = MIN (ay1, by1) - MAX (ay0, by0);
  float inter, uni;

  if (iw <= 0.0f || ih <= 0.0f)
    return 0.0f;
  inter = iw * ih;
  uni = a->w * a->h + b->w * b->h - inter;
  return uni > 0.0f ? inter / uni : 0.0f;
}

/* Decode the detector's raw output -- BOXES (18 per anchor: centre
   offset, size, seven keypoints, in letterboxed pixels) and SCORES (a
   logit per anchor) -- into at most MAX palms, image-normalised, after
   MediaPipe's weighted non-maximum suppression: overlapping boxes
   (IoU > 0.3) merge into their score-weighted mean.  */
int
cmacs_ht_decode_palms (const float *boxes, const float *scores,
                       const float *anchors, int n_anchors, float threshold,
                       float scale, float padx, float pady, int img_w,
                       int img_h, CmacsHtPalm *out, int max)
{
  enum { CAND_MAX = 64 };
  CmacsHtPalm cand[CAND_MAX];
  bool used[CAND_MAX];
  int nc = 0, n = 0, i, j, k;
  float S = (float) CMACS_HT_PALM_SIZE;

  /* Letterbox-normalised U -> image-normalised.  */
#define LBX(u) (((u) * S - padx) / scale / (float) img_w)
#define LBY(v) (((v) * S - pady) / scale / (float) img_h)

  for (i = 0; i < n_anchors; i++)
    {
      float sc = sigmoid (scores[i]);
      const float *b = boxes + (size_t) i * 18;
      float ax = anchors[2 * i], ay = anchors[2 * i + 1];
      CmacsHtPalm p;
      int lo;

      if (sc < threshold)
        continue;
      p.cx = LBX (b[0] / S + ax);
      p.cy = LBY (b[1] / S + ay);
      p.w = b[2] / scale / (float) img_w;
      p.h = b[3] / scale / (float) img_h;
      for (k = 0; k < 7; k++)
        {
          p.kp[k][0] = LBX (b[4 + 2 * k] / S + ax);
          p.kp[k][1] = LBY (b[5 + 2 * k] / S + ay);
        }
      p.score = sc;
      /* Keep the best CAND_MAX, sorted by score, descending.  */
      if (nc == CAND_MAX && sc <= cand[nc - 1].score)
        continue;
      lo = nc < CAND_MAX ? nc++ : nc - 1;
      while (lo > 0 && cand[lo - 1].score < sc)
        {
          cand[lo] = cand[lo - 1];
          lo--;
        }
      cand[lo] = p;
    }
#undef LBX
#undef LBY

  memset (used, 0, sizeof used);
  for (i = 0; i < nc && n < max; i++)
    {
      CmacsHtPalm acc;
      float wsum;

      if (used[i])
        continue;
      memset (&acc, 0, sizeof acc);
      wsum = 0.0f;
      for (j = i; j < nc; j++)
        {
          float wgt;

          if (used[j] || (j != i && iou (&cand[i], &cand[j]) <= 0.3f))
            continue;
          used[j] = true;
          wgt = cand[j].score;
          acc.cx += cand[j].cx * wgt;
          acc.cy += cand[j].cy * wgt;
          acc.w += cand[j].w * wgt;
          acc.h += cand[j].h * wgt;
          for (k = 0; k < 7; k++)
            {
              acc.kp[k][0] += cand[j].kp[k][0] * wgt;
              acc.kp[k][1] += cand[j].kp[k][1] * wgt;
            }
          wsum += wgt;
        }
      acc.cx /= wsum;
      acc.cy /= wsum;
      acc.w /= wsum;
      acc.h /= wsum;
      for (k = 0; k < 7; k++)
        {
          acc.kp[k][0] /= wsum;
          acc.kp[k][1] /= wsum;
        }
      acc.score = cand[i].score;
      out[n++] = acc;
    }
  return n;
}

/* --------------------------------------------------------------- ROIs -- */

static float
normalize_angle (float a)
{
  while (a > (float) G_PI)
    a -= 2.0f * (float) G_PI;
  while (a < -(float) G_PI)
    a += 2.0f * (float) G_PI;
  return a;
}

/* The turn that puts the vector wrist -> middle knuckle straight up.  */
static float
hand_rotation (float x0, float y0, float x1, float y1)
{
  return normalize_angle ((float) G_PI / 2.0f - atan2f (-(y1 - y0), x1 - x0));
}

/* MediaPipe's rect transformation: shift by (0, SHIFT_Y) box heights in
   the box's own frame, then square to the long side times SCALE.  */
static void
transform_rect (float cx, float cy, float w, float h, float rotation,
                float shift_y, float scale, CmacsHtRoi *roi)
{
  roi->cx = cx - shift_y * h * sinf (rotation);
  roi->cy = cy + shift_y * h * cosf (rotation);
  roi->size = MAX (w, h) * scale;
  roi->rotation = rotation;
}

void
cmacs_ht_roi_from_palm (const CmacsHtPalm *palm, int img_w, int img_h,
                        CmacsHtRoi *roi)
{
  float W = (float) img_w, H = (float) img_h;
  float r = hand_rotation (palm->kp[0][0] * W, palm->kp[0][1] * H,
                           palm->kp[2][0] * W, palm->kp[2][1] * H);

  transform_rect (palm->cx * W, palm->cy * H, palm->w * W, palm->h * H, r,
                  -0.5f, 2.6f, roi);
}

void
cmacs_ht_roi_from_landmarks (const CmacsHtLandmarks *lm, int img_w,
                             int img_h, CmacsHtRoi *roi)
{
  /* The landmarks MediaPipe bounds a hand by: wrist, the thumb's base,
     and the base two joints of every finger -- the tips move too fast to
     predict the next frame's crop from.  */
  static const int subset[] = { 0, 1, 2, 3, 5, 6, 9, 10, 13, 14, 17, 18 };
  float W = (float) img_w, H = (float) img_h;
  float r = hand_rotation (lm->lm[0][0] * W, lm->lm[0][1] * H,
                           lm->lm[9][0] * W, lm->lm[9][1] * H);
  float c = cosf (r), s = sinf (r);
  float minx = G_MAXFLOAT, maxx = -G_MAXFLOAT, miny = G_MAXFLOAT,
        maxy = -G_MAXFLOAT, rx, ry;
  size_t i;

  /* The bounding box in the hand's own (rotated) frame.  */
  for (i = 0; i < G_N_ELEMENTS (subset); i++)
    {
      float x = lm->lm[subset[i]][0] * W, y = lm->lm[subset[i]][1] * H;
      float u = x * c + y * s, v = -x * s + y * c;
      minx = MIN (minx, u);
      maxx = MAX (maxx, u);
      miny = MIN (miny, v);
      maxy = MAX (maxy, v);
    }
  rx = (minx + maxx) / 2.0f;
  ry = (miny + maxy) / 2.0f;
  transform_rect (rx * c - ry * s, rx * s + ry * c, maxx - minx, maxy - miny,
                  r, -0.1f, 2.0f, roi);
}

/* ROI-local (U, V), each -0.5..0.5, to image pixels.  */
static void
roi_to_image (const CmacsHtRoi *roi, float u, float v, float *x, float *y)
{
  float c = cosf (roi->rotation), s = sinf (roi->rotation);

  *x = roi->cx + (u * c - v * s) * roi->size;
  *y = roi->cy + (u * s + v * c) * roi->size;
}

void
cmacs_ht_crop (const guint8 *rgb, int w, int h, int stride, bool mirror,
               const CmacsHtRoi *roi, int size, bool nchw, float *out)
{
  int x, y, c;

  for (y = 0; y < size; y++)
    for (x = 0; x < size; x++)
      {
        float px, py;

        roi_to_image (roi, ((float) x + 0.5f) / (float) size - 0.5f,
                      ((float) y + 0.5f) / (float) size - 0.5f, &px, &py);
        for (c = 0; c < 3; c++)
          store (out, size, nchw, x, y, c,
                 sample (rgb, w, h, stride, mirror, px - 0.5f, py - 0.5f, c));
      }
}

/* RAW: 21 x (x, y, z) in crop pixels (the landmark model's image
   output).  Into the image, normalised.  */
void
cmacs_ht_landmarks_from_crop (const float *raw, const CmacsHtRoi *roi,
                              int size, int img_w, int img_h,
                              CmacsHtLandmarks *out)
{
  int i;

  for (i = 0; i < CMACS_HT_LANDMARKS; i++)
    {
      float px, py;

      roi_to_image (roi, raw[3 * i] / (float) size - 0.5f,
                    raw[3 * i + 1] / (float) size - 0.5f, &px, &py);
      out->lm[i][0] = px / (float) img_w;
      out->lm[i][1] = py / (float) img_h;
      out->lm[i][2] = raw[3 * i + 2] / (float) size * roi->size
                      / (float) img_w;
    }
}

/* ------------------------------------------------- 21 landmarks <-> 26 -- */

/* MediaPipe landmark -> OpenXR joint.  MediaPipe has no palm joint and
   no metacarpal-base joint for the four fingers (its 5, 9, 13, 17 are
   the knuckles, OpenXR's PROXIMAL joints); those five are synthesised
   (see cmacs_ht_to_hand_state).  */
static const int mp_to_joint[CMACS_HT_LANDMARKS] = {
  LRG_VR_HAND_JOINT_WRIST,
  LRG_VR_HAND_JOINT_THUMB_METACARPAL, LRG_VR_HAND_JOINT_THUMB_PROXIMAL,
  LRG_VR_HAND_JOINT_THUMB_DISTAL, LRG_VR_HAND_JOINT_THUMB_TIP,
  LRG_VR_HAND_JOINT_INDEX_PROXIMAL, LRG_VR_HAND_JOINT_INDEX_INTERMEDIATE,
  LRG_VR_HAND_JOINT_INDEX_DISTAL, LRG_VR_HAND_JOINT_INDEX_TIP,
  LRG_VR_HAND_JOINT_MIDDLE_PROXIMAL, LRG_VR_HAND_JOINT_MIDDLE_INTERMEDIATE,
  LRG_VR_HAND_JOINT_MIDDLE_DISTAL, LRG_VR_HAND_JOINT_MIDDLE_TIP,
  LRG_VR_HAND_JOINT_RING_PROXIMAL, LRG_VR_HAND_JOINT_RING_INTERMEDIATE,
  LRG_VR_HAND_JOINT_RING_DISTAL, LRG_VR_HAND_JOINT_RING_TIP,
  LRG_VR_HAND_JOINT_LITTLE_PROXIMAL, LRG_VR_HAND_JOINT_LITTLE_INTERMEDIATE,
  LRG_VR_HAND_JOINT_LITTLE_DISTAL, LRG_VR_HAND_JOINT_LITTLE_TIP,
};

static void
v3_sub (const float *a, const float *b, float *o)
{
  o[0] = a[0] - b[0];
  o[1] = a[1] - b[1];
  o[2] = a[2] - b[2];
}

static void
v3_cross (const float *a, const float *b, float *o)
{
  float x = a[1] * b[2] - a[2] * b[1];
  float y = a[2] * b[0] - a[0] * b[2];
  float z = a[0] * b[1] - a[1] * b[0];
  o[0] = x;
  o[1] = y;
  o[2] = z;
}

static float
v3_norm (float *v)
{
  float l = sqrtf (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  if (l > 1e-9f)
    {
      v[0] /= l;
      v[1] /= l;
      v[2] /= l;
    }
  return l;
}

/* Unit quaternion (x y z w) of the rotation whose columns are X Y Z.  */
static void
quat_from_axes (const float *X, const float *Y, const float *Z, float *q)
{
  float tr = X[0] + Y[1] + Z[2], s;

  if (tr > 0.0f)
    {
      s = sqrtf (tr + 1.0f) * 2.0f;
      q[3] = 0.25f * s;
      q[0] = (Y[2] - Z[1]) / s;
      q[1] = (Z[0] - X[2]) / s;
      q[2] = (X[1] - Y[0]) / s;
    }
  else if (X[0] > Y[1] && X[0] > Z[2])
    {
      s = sqrtf (1.0f + X[0] - Y[1] - Z[2]) * 2.0f;
      q[3] = (Y[2] - Z[1]) / s;
      q[0] = 0.25f * s;
      q[1] = (Y[0] + X[1]) / s;
      q[2] = (Z[0] + X[2]) / s;
    }
  else if (Y[1] > Z[2])
    {
      s = sqrtf (1.0f + Y[1] - X[0] - Z[2]) * 2.0f;
      q[3] = (Z[0] - X[2]) / s;
      q[0] = (Y[0] + X[1]) / s;
      q[1] = 0.25f * s;
      q[2] = (Z[1] + Y[2]) / s;
    }
  else
    {
      s = sqrtf (1.0f + Z[2] - X[0] - Y[1]) * 2.0f;
      q[3] = (X[1] - Y[0]) / s;
      q[0] = (Z[0] + X[2]) / s;
      q[1] = (Z[1] + Y[2]) / s;
      q[2] = 0.25f * s;
    }
}

/* LM (image-normalised; ASPECT = height / width) as a libregnum hand in
   a viewer's space -- the user at the origin looking down -Z, +Y up,
   the camera's image on a plane in front -- so a camera hand is the same
   kind of thing a headset reports, and the same pinch latch, palm test
   and gesture classifier apply.  The image must be the mirrored (selfie)
   view, so its +x is the user's right.  RIGHT says which hand it is.

   Joints: the 21 landmarks map onto 21 of OpenXR's 26 (mp_to_joint).
   The other five are synthesised and marked valid: the palm, at the
   midpoint of the wrist and the middle knuckle (OpenXR's palm is the
   middle of the middle metacarpal), and each finger's metacarpal base,
   a quarter of the way from the wrist to its knuckle.  Every joint gets
   the palm's orientation -- MediaPipe gives positions only, and the palm
   frame is what the palm-up test reads.  */
void
cmacs_ht_to_hand_state (const CmacsHtLandmarks *lm, float aspect, bool right,
                        LrgVRHandState *out)
{
  static const struct { int joint, knuckle; } metacarpals[] = {
    { LRG_VR_HAND_JOINT_INDEX_METACARPAL, 5 },
    { LRG_VR_HAND_JOINT_MIDDLE_METACARPAL, 9 },
    { LRG_VR_HAND_JOINT_RING_METACARPAL, 13 },
    { LRG_VR_HAND_JOINT_LITTLE_METACARPAL, 17 },
  };
  float p[CMACS_HT_LANDMARKS][3], wrist[3], a[3], b[3], X[3], Y[3], Z[3],
        q[4], k = CMACS_HT_PLANE_W_M, palm_len, s, d;
  int i, j;
  size_t m;

  lrg_vr_hand_state_reset (out);

  /* Image -> viewer space.  */
  for (i = 0; i < CMACS_HT_LANDMARKS; i++)
    {
      p[i][0] = (lm->lm[i][0] - 0.5f) * k;
      p[i][1] = (0.5f - lm->lm[i][1]) * k * aspect;
      p[i][2] = -CMACS_HT_PLANE_M + lm->lm[i][2] * k;
    }

  /* A standard palm, whatever the distance to the camera.  */
  memcpy (wrist, p[0], sizeof wrist);
  v3_sub (p[9], p[0], a);
  palm_len = v3_norm (a);
  s = palm_len > 1e-6f ? CMACS_HT_PALM_M / palm_len : 1.0f;
  for (i = 0; i < CMACS_HT_LANDMARKS; i++)
    for (j = 0; j < 3; j++)
      p[i][j] = wrist[j] + (p[i][j] - wrist[j]) * s;

  out->active = true;
  for (i = 0; i < CMACS_HT_LANDMARKS; i++)
    memcpy (&out->positions[mp_to_joint[i] * 3], p[i], sizeof p[i]);
  for (j = 0; j < 3; j++)
    out->positions[LRG_VR_HAND_JOINT_PALM * 3 + j] = 0.5f * (p[0][j] + p[9][j]);
  for (m = 0; m < G_N_ELEMENTS (metacarpals); m++)
    for (j = 0; j < 3; j++)
      out->positions[metacarpals[m].joint * 3 + j]
        = p[0][j] + 0.25f * (p[metacarpals[m].knuckle][j] - p[0][j]);
  out->valid = (1u << LRG_VR_HAND_JOINT_COUNT) - 1u;

  /* The palm frame: +Y out of the back of the hand, +Z back along the
     fingers toward the wrist.  index x little (from the wrist) points
     out of the palm of a right hand and out of the back of a left.  */
  v3_sub (p[5], p[0], a);
  v3_sub (p[17], p[0], b);
  v3_cross (a, b, Y);
  if (right)
    {
      Y[0] = -Y[0];
      Y[1] = -Y[1];
      Y[2] = -Y[2];
    }
  v3_norm (Y);
  v3_sub (p[0], p[9], Z);
  d = Z[0] * Y[0] + Z[1] * Y[1] + Z[2] * Y[2];
  for (j = 0; j < 3; j++)
    Z[j] -= d * Y[j];
  v3_norm (Z);
  v3_cross (Y, Z, X);
  quat_from_axes (X, Y, Z, q);
  for (i = 0; i < LRG_VR_HAND_JOINT_COUNT; i++)
    {
      memcpy (&out->orientations[i * 4], q, sizeof q);
      out->radii[i] = (i == LRG_VR_HAND_JOINT_PALM
                       || i == LRG_VR_HAND_JOINT_WRIST) ? 0.012f : 0.008f;
    }
}

/* The inverse projection, for tests: a libregnum hand (synthetic, say)
   as the 21 landmarks a camera at the plane would see.  */
void
cmacs_ht_from_hand_state (const LrgVRHandState *st, float aspect,
                          CmacsHtLandmarks *out)
{
  float k = CMACS_HT_PLANE_W_M;
  int i;

  memset (out, 0, sizeof *out);
  for (i = 0; i < CMACS_HT_LANDMARKS; i++)
    {
      const float *p = &st->positions[mp_to_joint[i] * 3];
      out->lm[i][0] = p[0] / k + 0.5f;
      out->lm[i][1] = 0.5f - p[1] / (k * aspect);
      out->lm[i][2] = (p[2] + CMACS_HT_PLANE_M) / k;
    }
  out->presence = 1.0f;
  out->handedness = 1.0f;
}

#endif /* HAVE_CMACS_HANDTRACK */
