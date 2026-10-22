/* Camera hand tracking for CMacs -- internal interface.

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

SPDX-License-Identifier: AGPL-3.0-or-later  */

#ifndef CMACS_HANDTRACK_H
#define CMACS_HANDTRACK_H

#include <stdbool.h>
#include <glib.h>
#include <libregnum.h>

/* ------------------------------------------------------------------
   The split.

   `cmacs-handtrack-model.c'   pure arithmetic, MediaPipe's two-stage
       hand pipeline without the networks: letterbox and crop
       pre-processing, the palm detector's SSD anchors, box decoding and
       weighted NMS, the hand region of interest from a palm or from the
       previous frame's landmarks, landmarks back into the image, and
       the 21 MediaPipe landmarks <-> libregnum's 26-joint
       LrgVRHandState.  Testable with synthetic tensors.
   `cmacs-handtrack-ort.c'     onnxruntime sessions (HAVE_ONNXRUNTIME),
       or stubs that say it is missing.
   `cmacs-handtrack-worker.c'  the inference thread: takes frames from
       the camera's streaming thread, runs the pipeline, and posts each
       result to the main thread through the CMacs GLib loop.
   `cmacs-handtrack-defuns.c'  (lisp.h) the main-thread half: pinch
       latch, the shared gesture classifier (cmacs-hand-gesture.c),
       events, scene cameras, the Lisp API.
   None but the last sees `lisp.h'; nothing crossing between them is a
   Lisp_Object.
   ------------------------------------------------------------------ */

#define CMACS_HT_PALM_SIZE  192         /* palm detector input, pixels */
#define CMACS_HT_LMK_SIZE   224         /* landmark model input, pixels */
#define CMACS_HT_ANCHORS    2016        /* palm detector anchors (192) */
#define CMACS_HT_MAX_PALMS  8
#define CMACS_HT_MAX_HANDS  2
#define CMACS_HT_LANDMARKS  21

/* The image is mapped onto a virtual plane CMACS_HT_PLANE_M in front of
   the user, CMACS_HT_PLANE_W_M wide (a ~60 degree camera at that
   distance), and each hand scaled about its wrist to a palm (wrist to
   middle knuckle) of CMACS_HT_PALM_M -- so pinch distances, which the
   latch thresholds are in metres, do not depend on how far from the
   camera the hand is.  */
#define CMACS_HT_PLANE_M    0.50f
#define CMACS_HT_PLANE_W_M  0.577f
#define CMACS_HT_PALM_M     0.094f

/* A detected palm, image-normalised (0..1), with its seven keypoints:
   0 wrist, 1 index knuckle, 2 middle knuckle, 3 ring knuckle,
   4 little knuckle, 5 thumb base, 6 thumb knuckle.  */
typedef struct
{
  float cx, cy, w, h;
  float kp[7][2];
  float score;
} CmacsHtPalm;

/* A hand's region of interest: a square of SIZE pixels centred on
   (CX, CY), turned by ROTATION radians (fingers toward -Y at 0).  */
typedef struct
{
  float cx, cy, size, rotation;
} CmacsHtRoi;

/* One hand's 21 MediaPipe landmarks: x, y image-normalised; z in the
   same units as x, negative toward the camera.  */
typedef struct
{
  float lm[CMACS_HT_LANDMARKS][3];
  float presence;                /* landmark model's hand score, 0..1 */
  float handedness;              /* > 0.5: a right hand */
} CmacsHtLandmarks;

/* ------------------------------------------------------------ model.c -- */

extern int cmacs_ht_anchors (float *xy);

extern void cmacs_ht_letterbox (const guint8 *rgb, int w, int h, int stride,
                                bool mirror, int size, bool nchw,
                                float *out, float *scale, float *padx,
                                float *pady);

extern int cmacs_ht_decode_palms (const float *boxes, const float *scores,
                                  const float *anchors, int n_anchors,
                                  float threshold, float scale, float padx,
                                  float pady, int img_w, int img_h,
                                  CmacsHtPalm *out, int max);

extern void cmacs_ht_roi_from_palm (const CmacsHtPalm *palm, int img_w,
                                    int img_h, CmacsHtRoi *roi);
extern void cmacs_ht_roi_from_landmarks (const CmacsHtLandmarks *lm,
                                         int img_w, int img_h,
                                         CmacsHtRoi *roi);

extern void cmacs_ht_crop (const guint8 *rgb, int w, int h, int stride,
                           bool mirror, const CmacsHtRoi *roi, int size,
                           bool nchw, float *out);

extern void cmacs_ht_landmarks_from_crop (const float *raw,
                                          const CmacsHtRoi *roi, int size,
                                          int img_w, int img_h,
                                          CmacsHtLandmarks *out);

extern void cmacs_ht_to_hand_state (const CmacsHtLandmarks *lm,
                                    float aspect, bool right,
                                    LrgVRHandState *out);
extern void cmacs_ht_from_hand_state (const LrgVRHandState *st,
                                      float aspect, CmacsHtLandmarks *out);

/* -------------------------------------------------------------- ort.c -- */

typedef struct CmacsHtModel CmacsHtModel;

/* Whether this build can run the networks at all.  */
extern bool cmacs_ht_inference_available (void);
extern CmacsHtModel *cmacs_ht_model_load (const char *path, int threads,
                                          char **err);
extern void cmacs_ht_model_free (CmacsHtModel *m);
/* The model's single image input: SIZE pixels square, NCHW or NHWC.  */
extern bool cmacs_ht_model_input (CmacsHtModel *m, int *size, bool *nchw);
/* Run on INPUT (SIZE*SIZE*3 floats).  Fills up to MAX outputs, each a
   g_malloc'd float array (OUT[i]) of N[i] elements, in the model's
   output order; returns how many, or -1 with *ERR.  */
extern int cmacs_ht_model_run (CmacsHtModel *m, const float *input,
                               float **out, gsize *n, int max, char **err);

/* ----------------------------------------------------------- worker.c -- */

typedef struct
{
  int n;                         /* hands found */
  CmacsHtLandmarks hands[CMACS_HT_MAX_HANDS];
  int img_w, img_h;
  gint64 frame_us;               /* when the frame arrived */
  gint64 latency_us;             /* inference time */
  bool detected;                 /* the palm detector ran this frame */
} CmacsHtResult;

typedef void (*CmacsHtResultFunc) (const CmacsHtResult *r);

typedef struct
{
  const char *palm_model;
  const char *landmark_model;
  int threads;
  bool mirror;
  float palm_threshold;
  float presence_threshold;
} CmacsHtConfig;

/* Start the inference thread on the open camera.  HANDLER runs on the
   main thread with each result (the latest only: results coalesce when
   the main thread is busy).  */
extern bool cmacs_ht_worker_start (const CmacsHtConfig *cfg,
                                   CmacsHtResultFunc handler, char **err);
extern void cmacs_ht_worker_stop (void);
extern bool cmacs_ht_worker_running (void);
extern guint64 cmacs_ht_worker_frames (void);   /* frames inferred */

extern void syms_of_cmacs_handtrack_defuns (void);

#endif /* CMACS_HANDTRACK_H */
