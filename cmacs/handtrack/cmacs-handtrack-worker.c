/* Camera hand tracking for CMacs -- the inference thread.

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

Three threads meet here, and only here:

  camera streaming thread   on_frame copies the frame into `next' and
                            signals; it never waits for inference;
  inference thread          takes the newest frame (older ones are
                            simply overwritten), runs the networks, and
                            stores the result in `pending';
  main thread               deliver() runs from the CMacs GLib loop and
                            hands `pending' to the handler.  At most one
                            delivery is queued at a time, so a busy main
                            thread sees the latest result, not a backlog.

No Lisp anywhere in this file.  */

#include <config.h>

#ifdef HAVE_CMACS_HANDTRACK

#include <math.h>
#include <string.h>

#include "cmacs-glib-loop.h"
#include "cmacs-camera.h"
#include "cmacs-handtrack.h"

#define HT_MAX_OUT 8

static struct
{
  bool running;
  GThread *thread;
  guint consumer;
  CmacsHtConfig cfg;
  CmacsHtModel *palm, *lmk;
  int palm_size, lmk_size;
  bool palm_nchw, lmk_nchw;
  CmacsHtResultFunc handler;
  float anchors[CMACS_HT_ANCHORS * 2];

  GMutex lock;                   /* everything below */
  GCond cond;
  bool quit;
  guint8 *next;                  /* newest frame, packed RGB */
  int next_w, next_h;
  gint64 next_us;
  bool have_next;
  CmacsHtResult pending;
  bool posted;
  guint64 inferred;
} ht;

/* ---------------------------------------------------------- frames in -- */

static void
on_frame (const guint8 *rgb, int w, int h, int stride, gint64 pts,
          gpointer data)
{
  int y;

  (void) pts;
  (void) data;
  g_mutex_lock (&ht.lock);
  if (ht.next == NULL || ht.next_w != w || ht.next_h != h)
    {
      g_free (ht.next);
      ht.next = g_malloc ((gsize) w * (gsize) h * 3);
      ht.next_w = w;
      ht.next_h = h;
    }
  for (y = 0; y < h; y++)
    memcpy (ht.next + (gsize) y * (gsize) w * 3, rgb + (gsize) y * (gsize) stride,
            (gsize) w * 3);
  ht.next_us = g_get_monotonic_time ();
  ht.have_next = true;
  g_cond_signal (&ht.cond);
  g_mutex_unlock (&ht.lock);
}

/* -------------------------------------------------------- results out -- */

static gboolean
deliver (gpointer data)
{
  CmacsHtResult r;

  (void) data;
  g_mutex_lock (&ht.lock);
  r = ht.pending;
  ht.posted = false;
  g_mutex_unlock (&ht.lock);
  if (ht.running && ht.handler != NULL)
    ht.handler (&r);
  return G_SOURCE_REMOVE;
}

static void
post (const CmacsHtResult *r)
{
  bool queue;

  g_mutex_lock (&ht.lock);
  ht.pending = *r;
  ht.inferred++;
  queue = !ht.posted;
  ht.posted = true;
  g_mutex_unlock (&ht.lock);
  if (queue)
    cmacs_glib_invoke_on_main (deliver, NULL, NULL);
}

/* ------------------------------------------------------------ pipeline -- */

static void
free_outputs (float **out, int n)
{
  int i;

  for (i = 0; i < n; i++)
    g_free (out[i]);
}

/* The palm detector's two outputs, found by size, not position, since
   conversions order them differently: 18 floats per anchor are boxes,
   one per anchor are scores.  */
static int
detect (const guint8 *rgb, int w, int h, CmacsHtPalm *palms)
{
  float *in, *out[HT_MAX_OUT] = { NULL };
  gsize n[HT_MAX_OUT] = { 0 };
  float scale, padx, pady;
  const float *boxes = NULL, *scores = NULL;
  char *err = NULL;
  int k, got, found = 0;

  in = g_new (float, (gsize) ht.palm_size * ht.palm_size * 3);
  cmacs_ht_letterbox (rgb, w, h, w * 3, ht.cfg.mirror, ht.palm_size,
                      ht.palm_nchw, in, &scale, &padx, &pady);
  got = cmacs_ht_model_run (ht.palm, in, out, n, HT_MAX_OUT, &err);
  g_free (in);
  g_free (err);
  for (k = 0; k < got; k++)
    {
      if (n[k] == (gsize) CMACS_HT_ANCHORS * 18)
        boxes = out[k];
      else if (n[k] == (gsize) CMACS_HT_ANCHORS)
        scores = out[k];
    }
  if (boxes != NULL && scores != NULL)
    found = cmacs_ht_decode_palms (boxes, scores, ht.anchors, CMACS_HT_ANCHORS,
                                   ht.cfg.palm_threshold, scale, padx, pady,
                                   w, h, palms, CMACS_HT_MAX_HANDS);
  free_outputs (out, got > 0 ? got : 0);
  return found;
}

/* Landmarks in ROI.  The image landmarks are the first 63-float output;
   the 1-float outputs are hand presence, then handedness.  */
static bool
landmarks (const guint8 *rgb, int w, int h, const CmacsHtRoi *roi,
           CmacsHtLandmarks *lm)
{
  float *in, *out[HT_MAX_OUT] = { NULL };
  gsize n[HT_MAX_OUT] = { 0 };
  const float *pts = NULL;
  char *err = NULL;
  int k, got, ones = 0;
  bool ok = false;

  in = g_new (float, (gsize) ht.lmk_size * ht.lmk_size * 3);
  cmacs_ht_crop (rgb, w, h, w * 3, ht.cfg.mirror, roi, ht.lmk_size,
                 ht.lmk_nchw, in);
  got = cmacs_ht_model_run (ht.lmk, in, out, n, HT_MAX_OUT, &err);
  g_free (in);
  g_free (err);
  lm->presence = 0.0f;
  lm->handedness = 0.5f;
  for (k = 0; k < got; k++)
    {
      if (n[k] == 63 && pts == NULL)
        pts = out[k];
      else if (n[k] == 1)
        {
          if (ones++ == 0)
            lm->presence = out[k][0];
          else
            lm->handedness = out[k][0];
        }
    }
  if (pts != NULL)
    {
      cmacs_ht_landmarks_from_crop (pts, roi, ht.lmk_size, w, h, lm);
      ok = lm->presence >= ht.cfg.presence_threshold;
    }
  free_outputs (out, got > 0 ? got : 0);
  return ok;
}

static gpointer
infer_thread (gpointer data)
{
  guint8 *frame = NULL;
  int fw = 0, fh = 0;
  CmacsHtLandmarks tracked[CMACS_HT_MAX_HANDS];
  int n_tracked = 0;

  (void) data;
  for (;;)
    {
      CmacsHtResult r;
      CmacsHtRoi rois[CMACS_HT_MAX_HANDS];
      int n_rois = 0, i, j;
      gint64 t0, frame_us;

      g_mutex_lock (&ht.lock);
      while (!ht.quit && !ht.have_next)
        g_cond_wait (&ht.cond, &ht.lock);
      if (ht.quit)
        {
          g_mutex_unlock (&ht.lock);
          break;
        }
      /* Swap rather than copy: the camera writes the next frame into
         what was ours.  */
      {
        guint8 *t = frame;
        int tw = fw, th = fh;
        frame = ht.next;
        fw = ht.next_w;
        fh = ht.next_h;
        ht.next = t;
        ht.next_w = tw;
        ht.next_h = th;
      }
      frame_us = ht.next_us;
      ht.have_next = false;
      g_mutex_unlock (&ht.lock);

      t0 = g_get_monotonic_time ();
      memset (&r, 0, sizeof r);
      r.img_w = fw;
      r.img_h = fh;
      r.frame_us = frame_us;

      /* Track from last frame's landmarks; detect only when a hand is
         missing -- the detector costs several times the landmarks.  */
      for (i = 0; i < n_tracked; i++)
        cmacs_ht_roi_from_landmarks (&tracked[i], fw, fh, &rois[n_rois++]);
      if (n_rois < CMACS_HT_MAX_HANDS)
        {
          CmacsHtPalm palms[CMACS_HT_MAX_HANDS];
          int np = detect (frame, fw, fh, palms);

          r.detected = true;
          for (i = 0; i < np && n_rois < CMACS_HT_MAX_HANDS; i++)
            {
              CmacsHtRoi roi;
              bool dup = false;

              cmacs_ht_roi_from_palm (&palms[i], fw, fh, &roi);
              /* A palm already tracked is not a second hand.  */
              for (j = 0; j < n_rois; j++)
                if (hypotf (roi.cx - rois[j].cx, roi.cy - rois[j].cy)
                    < 0.5f * MIN (roi.size, rois[j].size))
                  dup = true;
              if (!dup)
                rois[n_rois++] = roi;
            }
        }
      n_tracked = 0;
      for (i = 0; i < n_rois; i++)
        if (landmarks (frame, fw, fh, &rois[i], &r.hands[r.n]))
          {
            tracked[n_tracked++] = r.hands[r.n];
            r.n++;
          }
      r.latency_us = g_get_monotonic_time () - t0;
      post (&r);
    }
  g_free (frame);
  return NULL;
}

/* -------------------------------------------------------------- control -- */

bool
cmacs_ht_worker_start (const CmacsHtConfig *cfg, CmacsHtResultFunc handler,
                       char **err)
{
  static bool inited;

  *err = NULL;
  if (ht.running)
    return true;
  if (!cmacs_ht_inference_available ())
    {
      *err = g_strdup ("cmacs was built without onnxruntime");
      return false;
    }
  if (!cmacs_camera_is_open ())
    {
      *err = g_strdup ("the camera is not open");
      return false;
    }
  if (!inited)
    {
      g_mutex_init (&ht.lock);
      g_cond_init (&ht.cond);
      inited = true;
    }
  ht.palm = cmacs_ht_model_load (cfg->palm_model, cfg->threads, err);
  if (ht.palm == NULL)
    return false;
  ht.lmk = cmacs_ht_model_load (cfg->landmark_model, cfg->threads, err);
  if (ht.lmk == NULL)
    {
      g_clear_pointer (&ht.palm, cmacs_ht_model_free);
      return false;
    }
  cmacs_ht_model_input (ht.palm, &ht.palm_size, &ht.palm_nchw);
  cmacs_ht_model_input (ht.lmk, &ht.lmk_size, &ht.lmk_nchw);
  if (ht.palm_size <= 0)
    ht.palm_size = CMACS_HT_PALM_SIZE;
  if (ht.lmk_size <= 0)
    ht.lmk_size = CMACS_HT_LMK_SIZE;
  if (ht.palm_size != CMACS_HT_PALM_SIZE)
    {
      *err = g_strdup_printf ("palm model input is %d pixels; the decoder "
                              "is MediaPipe's 192", ht.palm_size);
      cmacs_ht_worker_stop ();
      return false;
    }
  cmacs_ht_anchors (ht.anchors);

  ht.cfg = *cfg;
  ht.cfg.palm_model = ht.cfg.landmark_model = NULL;
  ht.handler = handler;
  ht.quit = false;
  ht.have_next = false;
  ht.posted = false;
  ht.inferred = 0;
  ht.running = true;
  ht.thread = g_thread_new ("cmacs-handtrack", infer_thread, NULL);
  ht.consumer = cmacs_camera_add_consumer (on_frame, NULL);
  return true;
}

void
cmacs_ht_worker_stop (void)
{
  if (ht.consumer != 0)
    cmacs_camera_remove_consumer (ht.consumer);   /* no more frames */
  ht.consumer = 0;
  if (ht.thread != NULL)
    {
      g_mutex_lock (&ht.lock);
      ht.quit = true;
      g_cond_signal (&ht.cond);
      g_mutex_unlock (&ht.lock);
      g_thread_join (ht.thread);
      ht.thread = NULL;
    }
  ht.running = false;            /* a queued delivery now does nothing */
  g_clear_pointer (&ht.palm, cmacs_ht_model_free);
  g_clear_pointer (&ht.lmk, cmacs_ht_model_free);
  g_clear_pointer (&ht.next, g_free);
  ht.have_next = false;
}

bool
cmacs_ht_worker_running (void)
{
  return ht.running;
}

guint64
cmacs_ht_worker_frames (void)
{
  guint64 n;

  if (!ht.running)
    return 0;
  g_mutex_lock (&ht.lock);
  n = ht.inferred;
  g_mutex_unlock (&ht.lock);
  return n;
}

#endif /* HAVE_CMACS_HANDTRACK */
