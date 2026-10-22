/* Camera capture for CMacs -- internal interface.

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

#ifndef CMACS_CAMERA_H
#define CMACS_CAMERA_H

#include <stdbool.h>
#include <glib.h>

/* ------------------------------------------------------------------
   The split, and the privacy model.

   `cmacs-camera-gst.c' owns the GStreamer pipeline and never sees
   `lisp.h': a source (a GstDevice's own element -- pipewiresrc or
   v4l2src --, the xdg Camera portal's PipeWire remote when sandboxed, or
   videotestsrc for tests), then videoconvert ! videoscale ! videorate
   to packed RGB at the configured size and rate, into an appsink.
   Frames arrive on GStreamer's streaming thread -- a worker, never the
   main thread -- where consumers (hand tracking) take them; the latest
   one is also kept, in memory, for a preview.

   Privacy: nothing opens a camera except `cmacs-camera-start' (or a
   feature the user started that calls it), nothing is written to disk
   anywhere in this subsystem, and `cmacs-camera-stop' sets the pipeline
   to NULL -- which closes the device, turning its light off -- before
   it returns.  The Lisp half shows an indicator while it is open.
   ------------------------------------------------------------------ */

/* Called on the streaming thread with each frame: packed RGB, STRIDE
   bytes per row.  The buffer is only valid during the call.  */
typedef void (*CmacsCameraFrameFunc) (const guint8 *rgb, int width,
                                      int height, int stride,
                                      gint64 pts_us, gpointer data);

/* Initialise GStreamer once.  False (and *ERR, g_free it) on failure.  */
extern bool cmacs_camera_init (char **err);

/* Open the camera.  SPEC names the source:
     NULL or ""         the first camera the device monitor lists,
                        PipeWire's before V4L2's; inside a Flatpak, the
                        Camera portal
     "test" / "test:P"  videotestsrc (pattern P, e.g. "ball")
     "/dev/videoN"      v4l2src on that node
     "pipewire:SERIAL"  pipewiresrc on that PipeWire object
     "portal"           the xdg-desktop-portal Camera, then PipeWire
     anything else      a device whose display name contains it
   Frames are WIDTH x HEIGHT at FPS.  A portal open completes later (the
   user may be asked); `cmacs_camera_is_open' turns true when it does.
   Returns false with *ERR on immediate failure.  */
extern bool cmacs_camera_open (const char *spec, int width, int height,
                               int fps, char **err);
extern void cmacs_camera_close (void);
extern bool cmacs_camera_is_open (void);
extern bool cmacs_camera_is_pending (void);  /* waiting for the portal */
extern const char *cmacs_camera_source_desc (void);
extern const char *cmacs_camera_last_error (void);
extern guint64 cmacs_camera_frame_count (void);
extern void cmacs_camera_frame_size (int *width, int *height);
extern bool cmacs_camera_sandboxed (void);

/* Frame consumers (streaming thread).  */
extern guint cmacs_camera_add_consumer (CmacsCameraFrameFunc fn,
                                        gpointer data);
extern void cmacs_camera_remove_consumer (guint id);

/* A copy of the latest frame, nearest-scaled to at most MAX_WIDTH wide:
   packed RGB, g_free it.  NULL when there is none.  */
extern guint8 *cmacs_camera_latest_rgb (int max_width, int *width,
                                        int *height);

/* Devices: each entry is three strings, name / API ("pipewire",
   "v4l2", ...) / a spec `cmacs_camera_open' accepts.  */
typedef struct
{
  char *name;
  char *api;
  char *spec;
} CmacsCameraDevice;

extern GPtrArray *cmacs_camera_list_devices (void);   /* free with
                                                         g_ptr_array_unref */

extern void syms_of_cmacs_camera_defuns (void);

#endif /* CMACS_CAMERA_H */
