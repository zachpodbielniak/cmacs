/* cmacs-video-defuns.c --- All cmacs-video DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * One translation unit for every DEFUN so the public API is greppable
 * in one place.  Each DEFUN locks the registry, looks up the stream,
 * dispatches, returns.  Lisp values are mapped to/from
 * CmacsVideoStream fields via the helpers in cmacs-video-stream.c.
 */

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "lisp.h"
#include "frame.h"
#include "buffer.h"
#include "coding.h"

#include "cmacs-video.h"
#include "cmacs-video-stream.h"
#include "cmacs-video-registry.h"
#include "cmacs-video-overlay.h"

#include <gst/gst.h>
#include <cairo.h>

/* ====================================================================
 * Keyword symbols (DEFUN argument parsing)
 *
 * QCwidth, QCheight, QCinsecure, QCvolume are already DEFSYM'd by
 * other Emacs subsystems (xfaces, etc.) and visible via globals.h.
 * The rest we DEFSYM ourselves in syms_of_cmacs_video_defuns.
 * ==================================================================== */

/* Qcv_audio, Qcv_loop, Qcv_autoplay, Qcv_start, Qcv_latency,
 * Qcv_on_state, and Qcmacs_video_error are all declared by
 * make-docfile in src/globals.h once DEFSYM'd below.  No file-local
 * forward decls needed. */

/* ====================================================================
 * Helpers
 * ==================================================================== */

static CmacsVideoStream *
cv_lookup_or_error (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  uint64_t h = (uint64_t) XFIXNUM (handle);
  CmacsVideoStream *s = cmacs_video_registry_lookup (h);
  if (!s)
    xsignal2 (Qcmacs_video_error,
              build_string ("unknown or closed cmacs-video handle"),
              handle);
  return s;
}

static Lisp_Object
cv_plist_get (ptrdiff_t nargs, Lisp_Object *args, Lisp_Object key,
              ptrdiff_t start)
{
  for (ptrdiff_t i = start; i + 1 < nargs; i += 2)
    if (EQ (args[i], key))
      return args[i + 1];
  return Qnil;
}

/* ====================================================================
 * DEFUNs
 * ==================================================================== */

DEFUN ("cmacs-video-supported-p", Fcmacs_video_supported_p,
       Scmacs_video_supported_p, 0, 0, 0,
       doc: /* Return non-nil if cmacs was built with --with-cmacs-video
and the runtime GStreamer initialisation succeeded.  */)
  (void)
{
  return gst_is_initialized () ? Qt : Qnil;
}

DEFUN ("cmacs-video--open-1", Fcmacs_video__open_1,
       Scmacs_video__open_1, 1, MANY, 0,
       doc: /* Internal: open URI and return an opaque handle (integer).

End users should call `cmacs-video-open' from
lisp/cmacs/cmacs-video.el, which layers on the
`cmacs-video-rtsps-insecure-by-default' and
`cmacs-video-default-latency-ms' defcustoms before invoking this
C primitive.

URI may be file://, http(s)://, rtsp://, rtsps://, srt://, udp://, rtp://.

Optional keyword arguments:
  :width  W       Display width in pixels (default 640).
  :height H       Display height in pixels (default 360).
  :audio  BOOL    Default nil (muted, no audio sink).
  :volume FLOAT   0.0..1.0 (default 1.0).
  :loop   BOOL    Restart on EOS (file URIs only).
  :autoplay BOOL  Set state to PLAYING immediately (default t).
  :start  FLOAT   Initial seek in seconds.
  :insecure BOOL  RTSPS only: skip TLS validation.  Use cautiously.
  :latency INT    RTSP buffer in ms (default 200).
  :on-state FN    Function called as (FN HANDLE STATE-SYM &optional DETAIL)
                  on state changes (initializing, buffering, playing,
                  paused, stalled, reconnecting, eos, error, closed).
                  Always called on the main Emacs thread.

Signals `cmacs-video-error' on construction failure.

usage: (cmacs-video--open-1 URI &rest PLIST)  */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  CHECK_STRING (args[0]);
  if (!gst_is_initialized ())
    xsignal1 (Qcmacs_video_error,
              build_string ("cmacs-video: GStreamer not initialised"));

  Lisp_Object uri = ENCODE_FILE (args[0]);
  /* For non-file URIs, leave the bytes alone -- they're already ASCII/
   * UTF-8 from Lisp.  ENCODE_FILE on a URL is fine because URLs are
   * defined to be ASCII. */
  if (!STRINGP (uri))
    uri = args[0];

  CHECK_KEYWORD_ARGS (nargs - 1);

  Lisp_Object w_arg   = cv_plist_get (nargs, args, QCwidth,     1);
  Lisp_Object h_arg   = cv_plist_get (nargs, args, QCheight,    1);
  Lisp_Object aud_arg = cv_plist_get (nargs, args, Qcv_audio,    1);
  Lisp_Object vol_arg = cv_plist_get (nargs, args, QCvolume,    1);
  Lisp_Object loop_a  = cv_plist_get (nargs, args, Qcv_loop,     1);
  Lisp_Object ap_arg  = cv_plist_get (nargs, args, Qcv_autoplay, 1);
  Lisp_Object st_arg  = cv_plist_get (nargs, args, Qcv_start,    1);
  Lisp_Object ins_arg = cv_plist_get (nargs, args, QCinsecure,  1);
  Lisp_Object lat_arg = cv_plist_get (nargs, args, Qcv_latency,  1);
  Lisp_Object on_st   = cv_plist_get (nargs, args, Qcv_on_state, 1);

  int w = INTEGERP (w_arg) ? (int) XFIXNUM (w_arg) : 640;
  int h = INTEGERP (h_arg) ? (int) XFIXNUM (h_arg) : 360;

  GError *err = NULL;
  CmacsVideoStream *s = cmacs_video_stream_new (SSDATA (uri), w, h, &err);
  if (!s)
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-video: open failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_video_error, msg);
    }
  s->audio_enabled = !NILP (aud_arg);
  if (FLOATP (vol_arg) || INTEGERP (vol_arg))
    {
      double v = FLOATP (vol_arg) ? XFLOAT_DATA (vol_arg)
                                  : (double) XFIXNUM (vol_arg);
      s->volume = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
    }
  s->loop_p       = !NILP (loop_a);
  s->autoplay     = NILP (ap_arg) ? TRUE : !NILP (ap_arg);
  s->insecure_tls = !NILP (ins_arg);
  if (INTEGERP (lat_arg))
    s->latency_ms = (int) XFIXNUM (lat_arg);
  if (FLOATP (st_arg))
    s->start_ns = (gint64) (XFLOAT_DATA (st_arg) * GST_SECOND);
  else if (INTEGERP (st_arg))
    s->start_ns = (gint64) XFIXNUM (st_arg) * GST_SECOND;

  if (!NILP (on_st))
    cmacs_video_stream_add_state_handler (s, on_st);

  uint64_t handle = cmacs_video_registry_insert (s);

  /* Apply audio knobs after insertion in case they emit state. */
  if (s->audio_enabled && s->pipeline)
    g_object_set (s->pipeline, "volume", s->volume, NULL);

  if (s->autoplay)
    {
      if (s->start_ns > 0)
        {
          gst_element_set_state (s->pipeline, GST_STATE_PAUSED);
          cmacs_video_stream_seek_ns (s, s->start_ns);
        }
      cmacs_video_stream_play (s);
    }

  return make_int ((EMACS_INT) handle);
}

DEFUN ("cmacs-video-close", Fcmacs_video_close,
       Scmacs_video_close, 1, 1, 0,
       doc: /* Stop and destroy the stream identified by HANDLE.
Idempotent: closing an unknown or already-closed handle is a no-op.

This call blocks ~100-500ms for live streams (RTSP TEARDOWN handshake)
because GStreamer's state transition to NULL must complete before the
streaming threads unwind.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  uint64_t h = (uint64_t) XFIXNUM (handle);
  CmacsVideoStream *s = cmacs_video_registry_lookup (h);
  if (!s)
    return Qnil;
  /* Remove from registry first so paint hook drops it. */
  cmacs_video_registry_remove (h);
  if (s->standalone_frame)
    cmacs_video_registry_detach_frame (s->standalone_frame, s);
  cmacs_video_stream_destroy (s);
  return Qnil;
}

DEFUN ("cmacs-video-play", Fcmacs_video_play,
       Scmacs_video_play, 1, 1, 0,
       doc: /* Set state of HANDLE to PLAYING.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  cmacs_video_stream_play (s);
  return Qnil;
}

DEFUN ("cmacs-video-pause", Fcmacs_video_pause,
       Scmacs_video_pause, 1, 1, 0,
       doc: /* Set state of HANDLE to PAUSED.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  cmacs_video_stream_pause (s);
  return Qnil;
}

DEFUN ("cmacs-video-stop", Fcmacs_video_stop,
       Scmacs_video_stop, 1, 1, 0,
       doc: /* Set state of HANDLE to READY (stops decode without closing).  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  cmacs_video_stream_stop (s);
  return Qnil;
}

DEFUN ("cmacs-video-seek", Fcmacs_video_seek,
       Scmacs_video_seek, 2, 2, 0,
       doc: /* Seek HANDLE to POSITION-SECONDS (float or integer).  */)
  (Lisp_Object handle, Lisp_Object position_seconds)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  double secs = 0.0;
  if (FLOATP (position_seconds))
    secs = XFLOAT_DATA (position_seconds);
  else if (INTEGERP (position_seconds))
    secs = (double) XFIXNUM (position_seconds);
  else
    xsignal1 (Qwrong_type_argument, position_seconds);
  cmacs_video_stream_seek_ns (s, (gint64)(secs * GST_SECOND));
  return Qnil;
}

DEFUN ("cmacs-video-step", Fcmacs_video_step,
       Scmacs_video_step, 2, 2, 0,
       doc: /* Step HANDLE by N frames forward (positive) or backward
(negative).  Backward steps are approximated via keyframe seek.  */)
  (Lisp_Object handle, Lisp_Object n)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  CHECK_INTEGER (n);
  cmacs_video_stream_step (s, (int) XFIXNUM (n));
  return Qnil;
}

DEFUN ("cmacs-video-position", Fcmacs_video_position,
       Scmacs_video_position, 1, 1, 0,
       doc: /* Return (POSITION-NS . DURATION-NS) for HANDLE, or nil.
DURATION-NS is nil for live streams.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  gint64 pos = cmacs_video_stream_position_ns (s);
  gint64 dur = cmacs_video_stream_duration_ns (s);
  if (pos < 0)
    return Qnil;
  Lisp_Object dl = (dur < 0 || s->is_live) ? Qnil : make_int ((EMACS_INT) dur);
  return Fcons (make_int ((EMACS_INT) pos), dl);
}

DEFUN ("cmacs-video-state", Fcmacs_video_state,
       Scmacs_video_state, 1, 1, 0,
       doc: /* Return the current state symbol of HANDLE.
One of: 'initializing 'buffering 'playing 'paused 'stalled
'reconnecting 'eos 'error 'closed.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  return cmacs_video_state_symbol (s->state);
}

DEFUN ("cmacs-video-frames-decoded", Fcmacs_video_frames_decoded,
       Scmacs_video_frames_decoded, 1, 1, 0,
       doc: /* Return the count of frames decoded since open.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  g_mutex_lock (&s->frame_mtx);
  gint64 n = s->frames_decoded;
  g_mutex_unlock (&s->frame_mtx);
  return make_int ((EMACS_INT) n);
}

DEFUN ("cmacs-video-frame-size", Fcmacs_video_frame_size,
       Scmacs_video_frame_size, 1, 1, 0,
       doc: /* Return (W . H) native decoded size for HANDLE, or nil.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  g_mutex_lock (&s->frame_mtx);
  int w = s->frame_w, h = s->frame_h;
  g_mutex_unlock (&s->frame_mtx);
  if (w <= 0 || h <= 0)
    return Qnil;
  return Fcons (make_fixnum (w), make_fixnum (h));
}

DEFUN ("cmacs-video-set-volume", Fcmacs_video_set_volume,
       Scmacs_video_set_volume, 2, 2, 0,
       doc: /* Set audio volume of HANDLE to VOLUME (0.0..1.0).  */)
  (Lisp_Object handle, Lisp_Object volume)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  double v = 1.0;
  if (FLOATP (volume))   v = XFLOAT_DATA (volume);
  else if (INTEGERP (volume)) v = (double) XFIXNUM (volume);
  else xsignal1 (Qwrong_type_argument, volume);
  cmacs_video_stream_set_volume (s, v);
  return Qnil;
}

DEFUN ("cmacs-video-set-mute", Fcmacs_video_set_mute,
       Scmacs_video_set_mute, 2, 2, 0,
       doc: /* Set mute state of HANDLE.  When MUTE is non-nil, audio
is silenced without stopping the audio sink.  */)
  (Lisp_Object handle, Lisp_Object mute)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  cmacs_video_stream_set_mute (s, !NILP (mute));
  return Qnil;
}

DEFUN ("cmacs-video-set-size", Fcmacs_video_set_size,
       Scmacs_video_set_size, 3, 3, 0,
       doc: /* Update target display size of HANDLE to W x H (pixels).  */)
  (Lisp_Object handle, Lisp_Object w, Lisp_Object h)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  CHECK_INTEGER (w);
  CHECK_INTEGER (h);
  s->target_w = (int) XFIXNUM (w);
  s->target_h = (int) XFIXNUM (h);
  return Qnil;
}

DEFUN ("cmacs-video-attach-buffer", Fcmacs_video_attach_buffer,
       Scmacs_video_attach_buffer, 2, 2, 0,
       doc: /* Anchor HANDLE to buffer MARKER for inline overlay paint.
The buffer must add HANDLE to its `cmacs-video--streams' list before
the paint hook will draw the stream.  */)
  (Lisp_Object handle, Lisp_Object marker)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  if (!MARKERP (marker))
    xsignal1 (Qwrong_type_argument, marker);
  cmacs_video_stream_attach_buffer (s, marker);
  return Qnil;
}

DEFUN ("cmacs-video-attach-frame", Fcmacs_video_attach_frame,
       Scmacs_video_attach_frame, 6, 6, 0,
       doc: /* Anchor HANDLE to FRAME at the pixel rect (X Y W H).
Used by `cmacs-video-mode' for full-window playback.  */)
  (Lisp_Object handle, Lisp_Object frame,
   Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  CHECK_LIVE_FRAME (frame);
  CHECK_INTEGER (x);
  CHECK_INTEGER (y);
  CHECK_INTEGER (w);
  CHECK_INTEGER (h);
  struct frame *f = XFRAME (frame);
  /* Re-attach: detach old frame list entry if any. */
  if (s->standalone_frame && s->standalone_frame != f)
    cmacs_video_registry_detach_frame (s->standalone_frame, s);
  cmacs_video_stream_attach_frame (s, f,
                                   (int) XFIXNUM (x), (int) XFIXNUM (y),
                                   (int) XFIXNUM (w), (int) XFIXNUM (h));
  cmacs_video_registry_attach_frame (f, s);
  return Qnil;
}

DEFUN ("cmacs-video-detach", Fcmacs_video_detach,
       Scmacs_video_detach, 1, 1, 0,
       doc: /* Clear anchor on HANDLE without closing the stream.  */)
  (Lisp_Object handle)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  if (s->standalone_frame)
    cmacs_video_registry_detach_frame (s->standalone_frame, s);
  cmacs_video_stream_detach (s);
  return Qnil;
}

DEFUN ("cmacs-video-snapshot-to-file", Fcmacs_video_snapshot_to_file,
       Scmacs_video_snapshot_to_file, 2, 2, 0,
       doc: /* Write current frame of HANDLE to PATH as PNG.
Returns t on success, nil if no frame is available yet.  */)
  (Lisp_Object handle, Lisp_Object path)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  CHECK_STRING (path);
  cairo_surface_t *snap = cmacs_video_stream_snapshot (s);
  if (!snap)
    return Qnil;
  Lisp_Object encoded = ENCODE_FILE (path);
  cairo_status_t st = cairo_surface_write_to_png (snap, SSDATA (encoded));
  cairo_surface_destroy (snap);
  return (st == CAIRO_STATUS_SUCCESS) ? Qt : Qnil;
}

DEFUN ("cmacs-video-add-state-handler", Fcmacs_video_add_state_handler,
       Scmacs_video_add_state_handler, 2, 2, 0,
       doc: /* Add FN as a state-change handler for HANDLE.
FN is called as (FN HANDLE STATE-SYM &optional DETAIL) on the main
thread.  Errors are caught via `safe_calln' and logged to *Messages*
without unwinding the stream.  */)
  (Lisp_Object handle, Lisp_Object fn)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  cmacs_video_stream_add_state_handler (s, fn);
  return Qnil;
}

DEFUN ("cmacs-video-remove-state-handler", Fcmacs_video_remove_state_handler,
       Scmacs_video_remove_state_handler, 2, 2, 0,
       doc: /* Remove FN from the state-change handler list of HANDLE.  */)
  (Lisp_Object handle, Lisp_Object fn)
{
  CmacsVideoStream *s = cv_lookup_or_error (handle);
  cmacs_video_stream_remove_state_handler (s, fn);
  return Qnil;
}

DEFUN ("cmacs-video-list", Fcmacs_video_list,
       Scmacs_video_list, 0, 0, 0,
       doc: /* Return a list of all live cmacs-video stream handles.  */)
  (void)
{
  GList *handles = cmacs_video_registry_handles ();
  Lisp_Object out = Qnil;
  for (GList *l = handles; l; l = l->next)
    {
      uint64_t *h = l->data;
      out = Fcons (make_int ((EMACS_INT)*h), out);
      g_free (h);
    }
  g_list_free (handles);
  return out;
}

DEFUN ("cmacs-video-promote-hardware-decoders",
       Fcmacs_video_promote_hardware_decoders,
       Scmacs_video_promote_hardware_decoders, 0, 0, 0,
       doc: /* Bump priority of hardware H.264 / H.265 decoders.
Promotes vaapi, V4L2, and NVDEC decoders via
`gst_plugin_feature_set_rank' to GST_RANK_PRIMARY + 1 so that
playbin3 selects them ahead of software libav decoders.  Saves
8-15% CPU per 720p stream on hardware that supports it.

May expose flaky vendor drivers on some hardware (black-frame
artefacts on certain streams).  Roll back by restarting cmacs.  */)
  (void)
{
  if (!gst_is_initialized ())
    return Qnil;
  static const char *hw_decoders[] = {
    "vaapih264dec", "vaapih265dec",
    "v4l2h264dec",  "v4l2h265dec",
    "nvh264dec",    "nvh265dec",
    NULL
  };
  GstRegistry *reg = gst_registry_get ();
  if (!reg)
    return Qnil;
  for (const char **n = hw_decoders; *n; n++)
    {
      GstPluginFeature *f = gst_registry_lookup_feature (reg, *n);
      if (f)
        {
          gst_plugin_feature_set_rank (f, GST_RANK_PRIMARY + 1);
          gst_object_unref (f);
        }
    }
  return Qt;
}

/* ====================================================================
 * Test-only: synthetic videotestsrc pipeline
 * ==================================================================== */

DEFUN ("cmacs-video--open-test-pipeline", Fcmacs_video__open_test_pipeline,
       Scmacs_video__open_test_pipeline, 2, 2, 0,
       doc: /* Build a `videotestsrc' synthetic pipeline of WxH and
return a handle.  Tests only.  */)
  (Lisp_Object w, Lisp_Object h)
{
  CHECK_INTEGER (w);
  CHECK_INTEGER (h);
  if (!gst_is_initialized ())
    xsignal1 (Qcmacs_video_error,
              build_string ("cmacs-video: GStreamer not initialised"));

  GError *err = NULL;
  CmacsVideoStream *s = cmacs_video_stream_new_test (
    (int) XFIXNUM (w), (int) XFIXNUM (h), &err);
  if (!s)
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-video test pipeline failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_video_error, msg);
    }
  uint64_t handle = cmacs_video_registry_insert (s);
  cmacs_video_stream_play (s);
  return make_int ((EMACS_INT) handle);
}

/* ====================================================================
 * Registration
 * ==================================================================== */

void syms_of_cmacs_video_defuns (void);
void
syms_of_cmacs_video_defuns (void)
{
  /* Keyword symbols.  QCwidth, QCheight, QCvolume, QCinsecure are
   * already DEFSYM'd elsewhere in Emacs (xfaces, fileio, etc.); we
   * just DEFSYM the cmacs-video-specific ones with cv_ prefix to
   * avoid future global-symbol collisions. */
  DEFSYM (Qcv_audio,    ":audio");
  DEFSYM (Qcv_loop,     ":loop");
  DEFSYM (Qcv_autoplay, ":autoplay");
  DEFSYM (Qcv_start,    ":start");
  DEFSYM (Qcv_latency,  ":latency");
  DEFSYM (Qcv_on_state, ":on-state");

  /* Error symbol + parent error hierarchy. */
  DEFSYM (Qcmacs_video_error, "cmacs-video-error");
  Fput (Qcmacs_video_error, Qerror_conditions,
        list2 (Qcmacs_video_error, Qerror));
  Fput (Qcmacs_video_error, Qerror_message,
        build_string ("CMacs video error"));

  defsubr (&Scmacs_video_supported_p);
  defsubr (&Scmacs_video__open_1);
  defsubr (&Scmacs_video_close);
  defsubr (&Scmacs_video_play);
  defsubr (&Scmacs_video_pause);
  defsubr (&Scmacs_video_stop);
  defsubr (&Scmacs_video_seek);
  defsubr (&Scmacs_video_step);
  defsubr (&Scmacs_video_position);
  defsubr (&Scmacs_video_state);
  defsubr (&Scmacs_video_frames_decoded);
  defsubr (&Scmacs_video_frame_size);
  defsubr (&Scmacs_video_set_volume);
  defsubr (&Scmacs_video_set_mute);
  defsubr (&Scmacs_video_set_size);
  defsubr (&Scmacs_video_attach_buffer);
  defsubr (&Scmacs_video_attach_frame);
  defsubr (&Scmacs_video_detach);
  defsubr (&Scmacs_video_snapshot_to_file);
  defsubr (&Scmacs_video_add_state_handler);
  defsubr (&Scmacs_video_remove_state_handler);
  defsubr (&Scmacs_video_list);
  defsubr (&Scmacs_video_promote_hardware_decoders);
  defsubr (&Scmacs_video__open_test_pipeline);
}

#endif /* HAVE_CMACS_VIDEO */
