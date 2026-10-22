/* Camera capture for CMacs -- Lisp API.

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

Thin: every DEFUN reads or drives cmacs-camera-gst.c on the main
thread.  The indicator, the toast and the preview are Lisp
(cmacs-camera.el).  */

#include <config.h>

#ifdef HAVE_CMACS_CAMERA

#include <string.h>
#include <glib.h>

#include "lisp.h"
#include "coding.h"
#include "cmacs-camera.h"

static Lisp_Object
camera_string_or_nil (const char *s)
{
  return s != NULL ? build_string (s) : Qnil;
}

DEFUN ("cmacs-camera-open", Fcmacs_camera_open, Scmacs_camera_open, 0, 4, 0,
       doc: /* Open the camera named by SPEC, delivering WIDTH x HEIGHT at FPS.
SPEC is nil or "" for the first camera found (PipeWire's before
V4L2's; inside a Flatpak, the xdg-desktop-portal Camera), "portal",
"/dev/videoN", "pipewire:SERIAL" (see `cmacs-camera-devices'), "test"
or "test:PATTERN" (GStreamer's videotestsrc, for tests), or part of a
device's name.  WIDTH, HEIGHT and FPS default to 640, 480 and 30.

Frames stay in memory: nothing is written to disk.  Prefer the command
`cmacs-camera-start', which also shows the indicator.  Return t, or
`pending' while a portal asks the user; signal an error on failure.  */)
  (Lisp_Object spec, Lisp_Object width, Lisp_Object height, Lisp_Object fps)
{
  char *err = NULL;
  const char *s = NULL;
  bool ok;

  if (!NILP (spec))
    {
      CHECK_STRING (spec);
      spec = ENCODE_FILE (spec);
      s = SSDATA (spec);
    }
  if (!NILP (width))
    CHECK_FIXNAT (width);
  if (!NILP (height))
    CHECK_FIXNAT (height);
  if (!NILP (fps))
    CHECK_FIXNAT (fps);
  ok = cmacs_camera_open (s, NILP (width) ? 640 : (int) XFIXNAT (width),
                          NILP (height) ? 480 : (int) XFIXNAT (height),
                          NILP (fps) ? 30 : (int) XFIXNAT (fps), &err);
  if (!ok)
    {
      Lisp_Object msg = build_string (err != NULL ? err : "camera failed");
      g_free (err);
      xsignal1 (Qerror, msg);
    }
  return cmacs_camera_is_pending () ? intern_c_string ("pending") : Qt;
}

DEFUN ("cmacs-camera-close", Fcmacs_camera_close, Scmacs_camera_close, 0, 0, 0,
       doc: /* Close the camera.  The device is released before this returns.  */)
  (void)
{
  cmacs_camera_close ();
  return Qnil;
}

DEFUN ("cmacs-camera-status", Fcmacs_camera_status, Scmacs_camera_status,
       0, 0, 0,
       doc: /* Return a plist describing the camera.
Keys: :open, :pending (a portal is asking the user), :source (what is
open), :frames (delivered since it opened), :width, :height, :error
\(the last error, kept after a close) and :sandboxed (inside a Flatpak,
where the portal is used).  */)
  (void)
{
  int w = 0, h = 0;

  cmacs_camera_frame_size (&w, &h);
  return list (intern_c_string (":open"), cmacs_camera_is_open () ? Qt : Qnil,
               intern_c_string (":pending"),
               cmacs_camera_is_pending () ? Qt : Qnil,
               intern_c_string (":source"),
               camera_string_or_nil (cmacs_camera_source_desc ()),
               intern_c_string (":frames"),
               make_uint (cmacs_camera_frame_count ()),
               intern_c_string (":width"), make_fixnum (w),
               intern_c_string (":height"), make_fixnum (h),
               intern_c_string (":error"),
               camera_string_or_nil (cmacs_camera_last_error ()),
               intern_c_string (":sandboxed"),
               cmacs_camera_sandboxed () ? Qt : Qnil);
}

DEFUN ("cmacs-camera-devices", Fcmacs_camera_devices, Scmacs_camera_devices,
       0, 0, 0,
       doc: /* Return the cameras GStreamer's device monitor sees.
Each is (NAME API SPEC); SPEC is what `cmacs-camera-open' takes.
Listing opens no camera.  */)
  (void)
{
  GPtrArray *devs = cmacs_camera_list_devices ();
  Lisp_Object out = Qnil;
  guint i;

  for (i = devs->len; i > 0; i--)
    {
      CmacsCameraDevice *d = g_ptr_array_index (devs, i - 1);
      out = Fcons (list3 (build_string (d->name), build_string (d->api),
                          build_string (d->spec)), out);
    }
  g_ptr_array_unref (devs);
  return out;
}

DEFUN ("cmacs-camera-frame-ppm", Fcmacs_camera_frame_ppm,
       Scmacs_camera_frame_ppm, 0, 1, 0,
       doc: /* Return the latest frame as a PPM image, a unibyte string.
At most MAX-WIDTH pixels wide (default 320), scaled down.  For the
preview: `create-image' takes it with DATA-P, so it never touches a
file.  Return nil when no frame has arrived.  */)
  (Lisp_Object max_width)
{
  guint8 *rgb;
  int w = 0, h = 0, hl;
  char head[64];
  Lisp_Object out;

  if (!NILP (max_width))
    CHECK_FIXNAT (max_width);
  rgb = cmacs_camera_latest_rgb (NILP (max_width) ? 320
                                 : (int) XFIXNAT (max_width), &w, &h);
  if (rgb == NULL)
    return Qnil;
  hl = g_snprintf (head, sizeof head, "P6\n%d %d\n255\n", w, h);
  out = make_uninit_string (hl + (ptrdiff_t) w * h * 3);
  memcpy (SDATA (out), head, (size_t) hl);
  memcpy (SDATA (out) + hl, rgb, (size_t) w * (size_t) h * 3);
  g_free (rgb);
  return out;
}

void
syms_of_cmacs_camera_defuns (void)
{
  defsubr (&Scmacs_camera_open);
  defsubr (&Scmacs_camera_close);
  defsubr (&Scmacs_camera_status);
  defsubr (&Scmacs_camera_devices);
  defsubr (&Scmacs_camera_frame_ppm);
}

#endif /* HAVE_CMACS_CAMERA */
