/* cmacs-audio-defuns.c --- All cmacs-audio DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "lisp.h"
#include "frame.h"
#include "buffer.h"
#include "coding.h"

#include "cmacs-audio.h"
#include "cmacs-audio-stream.h"
#include "cmacs-audio-registry.h"
#include "cmacs-audio-overlay.h"

#include <gst/gst.h>
#include <cairo.h>

extern gchar *cmacs_audio_waveform_to_svg (const int16_t *pcm, gsize n_frames,
                                           int channels, int width, int height,
                                           const char *colour);

/* ====================================================================
 * Helpers
 * ==================================================================== */

static CmacsAudioStream *
ca_lookup_or_error (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  uint64_t h = (uint64_t) XFIXNUM (handle);
  CmacsAudioStream *s = cmacs_audio_registry_lookup (h);
  if (!s)
    xsignal2 (Qcmacs_audio_error,
              build_string ("unknown or closed cmacs-audio handle"),
              handle);
  return s;
}

static Lisp_Object
ca_plist_get (ptrdiff_t nargs, Lisp_Object *args, Lisp_Object key,
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

DEFUN ("cmacs-audio-supported-p", Fcmacs_audio_supported_p,
       Scmacs_audio_supported_p, 0, 0, 0,
       doc: /* Return non-nil if cmacs was built with --with-cmacs-audio
and the runtime GStreamer initialisation succeeded.  */)
  (void)
{
  return gst_is_initialized () ? Qt : Qnil;
}

DEFUN ("cmacs-audio--capture-open-1", Fcmacs_audio__capture_open_1,
       Scmacs_audio__capture_open_1, 0, MANY, 0,
       doc: /* Open a capture stream and return an opaque handle (integer).

Keyword arguments:
  :source SYM     One of `auto', `pipewire', `pulse', `test', `coreaudio'
                  (default `auto', which prefers pipewiresrc).
  :device STR     ALSA / PipeWire device name (optional).
  :rate   N       Sample rate in Hz (default 16000, whisper-ready).
  :channels N     1 (mono) or 2 (stereo); default 1.
  :level-meter BOOL  Insert a `level' element to emit RMS / peak msgs.

Signals `cmacs-audio-error' on failure.

usage: (cmacs-audio--capture-open-1 &rest PLIST)  */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  if (!gst_is_initialized ())
    xsignal1 (Qcmacs_audio_error,
              build_string ("cmacs-audio: GStreamer not initialised"));

  Lisp_Object src_sym  = ca_plist_get (nargs, args, QCsource,  0);
  Lisp_Object dev      = ca_plist_get (nargs, args, QCdevice,  0);
  Lisp_Object rate_arg = ca_plist_get (nargs, args, QCrate,    0);
  Lisp_Object chan_arg = ca_plist_get (nargs, args, QCchannels, 0);
  Lisp_Object lvl_arg  = ca_plist_get (nargs, args, QClevel_meter, 0);

  CmacsAudioSourceKind kind = cmacs_audio_source_from_symbol (src_sym);
  int rate = INTEGERP (rate_arg) ? (int) XFIXNUM (rate_arg) : 16000;
  int chans = INTEGERP (chan_arg) ? (int) XFIXNUM (chan_arg) : 1;
  gboolean lvl = !NILP (lvl_arg);
  const char *dev_c = STRINGP (dev) ? SSDATA (dev) : NULL;

  GError *err = NULL;
  CmacsAudioStream *s = cmacs_audio_stream_new_capture (kind, dev_c, rate,
                                                        chans, lvl, &err);
  if (!s)
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-audio: capture open failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_audio_error, msg);
    }
  return make_int ((EMACS_INT) s->handle);
}

DEFUN ("cmacs-audio--playback-open-file-1",
       Fcmacs_audio__playback_open_file_1,
       Scmacs_audio__playback_open_file_1, 1, 1, 0,
       doc: /* Open a playback stream from URI (string).
URI may be file://, http(s)://.  Returns an opaque handle (integer).  */)
  (Lisp_Object uri)
{
  CHECK_STRING (uri);
  if (!gst_is_initialized ())
    xsignal1 (Qcmacs_audio_error,
              build_string ("cmacs-audio: GStreamer not initialised"));
  GError *err = NULL;
  CmacsAudioStream *s = cmacs_audio_stream_new_playback_file (SSDATA (uri), &err);
  if (!s)
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-audio: playback open failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_audio_error, msg);
    }
  return make_int ((EMACS_INT) s->handle);
}

DEFUN ("cmacs-audio--playback-open-pcm-1",
       Fcmacs_audio__playback_open_pcm_1,
       Scmacs_audio__playback_open_pcm_1, 2, 2, 0,
       doc: /* Open an empty PCM playback stream at RATE Hz, CHANNELS channels.
Use `cmacs-audio-push-pcm' to feed S16LE samples.  */)
  (Lisp_Object rate, Lisp_Object channels)
{
  CHECK_INTEGER (rate);
  CHECK_INTEGER (channels);
  if (!gst_is_initialized ())
    xsignal1 (Qcmacs_audio_error,
              build_string ("cmacs-audio: GStreamer not initialised"));
  GError *err = NULL;
  CmacsAudioStream *s = cmacs_audio_stream_new_playback_pcm (
    (int) XFIXNUM (rate), (int) XFIXNUM (channels), &err);
  if (!s)
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-audio: pcm playback open failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_audio_error, msg);
    }
  return make_int ((EMACS_INT) s->handle);
}

DEFUN ("cmacs-audio-close", Fcmacs_audio_close,
       Scmacs_audio_close, 1, 1, 0,
       doc: /* Close the audio stream HANDLE and release its resources.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  uint64_t h = (uint64_t) XFIXNUM (handle);
  CmacsAudioStream *s = cmacs_audio_registry_lookup (h);
  if (!s) return Qnil;
  cmacs_audio_registry_remove (h);
  cmacs_audio_stream_destroy (s);
  return Qt;
}

DEFUN ("cmacs-audio-start", Fcmacs_audio_start,
       Scmacs_audio_start, 1, 1, 0,
       doc: /* Set the stream to PLAYING.  */)
  (Lisp_Object handle)
{ cmacs_audio_stream_start (ca_lookup_or_error (handle)); return Qt; }

DEFUN ("cmacs-audio-stop", Fcmacs_audio_stop,
       Scmacs_audio_stop, 1, 1, 0,
       doc: /* Set the stream to READY (stops capture/playback).  */)
  (Lisp_Object handle)
{ cmacs_audio_stream_stop (ca_lookup_or_error (handle)); return Qt; }

DEFUN ("cmacs-audio-pause", Fcmacs_audio_pause,
       Scmacs_audio_pause, 1, 1, 0,
       doc: /* Set the stream to PAUSED.  */)
  (Lisp_Object handle)
{ cmacs_audio_stream_pause (ca_lookup_or_error (handle)); return Qt; }

DEFUN ("cmacs-audio-seek", Fcmacs_audio_seek,
       Scmacs_audio_seek, 2, 2, 0,
       doc: /* Seek playback to SECONDS (float).  */)
  (Lisp_Object handle, Lisp_Object seconds)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  CHECK_NUMBER (seconds);
  double secs = NUMBERP (seconds) ? XFLOATINT (seconds) : 0.0;
  cmacs_audio_stream_seek_ns (s, (gint64) (secs * GST_SECOND));
  return Qt;
}

DEFUN ("cmacs-audio-position", Fcmacs_audio_position,
       Scmacs_audio_position, 1, 1, 0,
       doc: /* Return (POS-NS . DUR-NS) or nil if unknown.  */)
  (Lisp_Object handle)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  gint64 pos = cmacs_audio_stream_position_ns (s);
  gint64 dur = cmacs_audio_stream_duration_ns (s);
  if (pos < 0 && dur < 0) return Qnil;
  return Fcons (make_int ((EMACS_INT) pos), make_int ((EMACS_INT) dur));
}

DEFUN ("cmacs-audio-state", Fcmacs_audio_state,
       Scmacs_audio_state, 1, 1, 0,
       doc: /* Return the current state symbol for HANDLE.  */)
  (Lisp_Object handle)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  return cmacs_audio_state_symbol (s->state);
}

DEFUN ("cmacs-audio-read-pcm", Fcmacs_audio_read_pcm,
       Scmacs_audio_read_pcm, 2, 2, 0,
       doc: /* Drain up to N-FRAMES samples from the capture front buffer.
Returns a unibyte string of S16LE bytes (length = nframes * 2 * channels),
or an empty string if no samples are available.  */)
  (Lisp_Object handle, Lisp_Object n_frames)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  CHECK_INTEGER (n_frames);
  guint req = (guint) XFIXNUM (n_frames);
  int16_t *buf = g_malloc0 (req * s->channels * sizeof (int16_t));
  guint got = cmacs_audio_stream_drain_pcm (s, buf, req);
  Lisp_Object out = make_unibyte_string ((const char *) buf,
                                         got * s->channels * sizeof (int16_t));
  g_free (buf);
  return out;
}

DEFUN ("cmacs-audio-push-pcm", Fcmacs_audio_push_pcm,
       Scmacs_audio_push_pcm, 2, 2, 0,
       doc: /* Push PCM (unibyte string of S16LE) into a playback-pcm
stream HANDLE.  Returns t on success.  */)
  (Lisp_Object handle, Lisp_Object pcm)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  CHECK_STRING (pcm);
  gsize bytes = SBYTES (pcm);
  guint nframes = bytes / (sizeof (int16_t) * s->channels);
  if (nframes == 0) return Qnil;
  return cmacs_audio_stream_push_pcm (s, (const int16_t *) SDATA (pcm), nframes)
         ? Qt : Qnil;
}

DEFUN ("cmacs-audio-write-file", Fcmacs_audio_write_file,
       Scmacs_audio_write_file, 2, 2, 0,
       doc: /* Write the capture buffer of HANDLE to PATH as a WAV file.
Returns t on success.  */)
  (Lisp_Object handle, Lisp_Object path)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  CHECK_STRING (path);
  Lisp_Object enc = ENCODE_FILE (path);
  GError *err = NULL;
  if (!cmacs_audio_stream_write_wav (s, SSDATA (enc), &err))
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-audio: write-wav failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_audio_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-audio-level", Fcmacs_audio_level,
       Scmacs_audio_level, 1, 1, 0,
       doc: /* Return (PEAK-DB . RMS-DB) most-recent reading, or nil if
the stream has no level meter.  */)
  (Lisp_Object handle)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  if (!s->level_meter_enabled) return Qnil;
  return Fcons (make_float (s->last_peak_db), make_float (s->last_rms_db));
}

DEFUN ("cmacs-audio-set-volume", Fcmacs_audio_set_volume,
       Scmacs_audio_set_volume, 2, 2, 0,
       doc: /* Set playback volume of HANDLE to V (0.0..1.0).  */)
  (Lisp_Object handle, Lisp_Object v)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  CHECK_NUMBER (v);
  cmacs_audio_stream_set_volume (s, XFLOATINT (v));
  return Qt;
}

DEFUN ("cmacs-audio-set-mute", Fcmacs_audio_set_mute,
       Scmacs_audio_set_mute, 2, 2, 0,
       doc: /* Mute (non-nil) or unmute (nil) HANDLE.  */)
  (Lisp_Object handle, Lisp_Object mute)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  cmacs_audio_stream_set_mute (s, !NILP (mute));
  return Qt;
}

DEFUN ("cmacs-audio-attach-buffer", Fcmacs_audio_attach_buffer,
       Scmacs_audio_attach_buffer, 2, 2, 0,
       doc: /* Anchor HANDLE to buffer marker MARKER.  */)
  (Lisp_Object handle, Lisp_Object marker)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  CHECK_TYPE (MARKERP (marker), Qmarkerp, marker);
  cmacs_audio_stream_attach_buffer (s, marker);
  return Qt;
}

DEFUN ("cmacs-audio-attach-frame", Fcmacs_audio_attach_frame,
       Scmacs_audio_attach_frame, 6, 6, 0,
       doc: /* Anchor HANDLE to FRAME at rectangle (X Y W H).  */)
  (Lisp_Object handle, Lisp_Object frame,
   Lisp_Object x, Lisp_Object y, Lisp_Object w, Lisp_Object h)
{
  CmacsAudioStream *s = ca_lookup_or_error (handle);
  struct frame *f = decode_live_frame (frame);
  CHECK_INTEGER (x); CHECK_INTEGER (y);
  CHECK_INTEGER (w); CHECK_INTEGER (h);
  cmacs_audio_stream_attach_frame (s, f,
                                   (int) XFIXNUM (x), (int) XFIXNUM (y),
                                   (int) XFIXNUM (w), (int) XFIXNUM (h));
  return Qt;
}

DEFUN ("cmacs-audio-detach", Fcmacs_audio_detach,
       Scmacs_audio_detach, 1, 1, 0,
       doc: /* Remove any buffer/frame anchoring from HANDLE.  */)
  (Lisp_Object handle)
{
  cmacs_audio_stream_detach (ca_lookup_or_error (handle));
  return Qt;
}

DEFUN ("cmacs-audio-waveform-svg", Fcmacs_audio_waveform_svg,
       Scmacs_audio_waveform_svg, 3, 4, 0,
       doc: /* Render PCM bytes (S16LE unibyte string, mono or interleaved
stereo) as an SVG waveform of WIDTH x HEIGHT.
Optional COLOUR is a CSS colour string (default "#3f7bd6").  */)
  (Lisp_Object pcm, Lisp_Object width, Lisp_Object height, Lisp_Object colour)
{
  CHECK_STRING (pcm);
  CHECK_INTEGER (width);
  CHECK_INTEGER (height);
  const char *c = NILP (colour) ? NULL
                : (CHECK_STRING (colour), SSDATA (colour));
  gsize bytes = SBYTES (pcm);
  gsize nframes = bytes / sizeof (int16_t);    /* mono assumption */
  gchar *svg = cmacs_audio_waveform_to_svg ((const int16_t *) SDATA (pcm),
                                            nframes, 1,
                                            (int) XFIXNUM (width),
                                            (int) XFIXNUM (height),
                                            c);
  Lisp_Object out = build_string (svg);
  g_free (svg);
  return out;
}

DEFUN ("cmacs-audio-add-state-handler", Fcmacs_audio_add_state_handler,
       Scmacs_audio_add_state_handler, 2, 2, 0,
       doc: /* Register FN to be called as (FN HANDLE STATE-SYM) on
state changes for HANDLE.  */)
  (Lisp_Object handle, Lisp_Object fn)
{
  cmacs_audio_stream_add_state_handler (ca_lookup_or_error (handle), fn);
  return Qt;
}

DEFUN ("cmacs-audio-remove-state-handler", Fcmacs_audio_remove_state_handler,
       Scmacs_audio_remove_state_handler, 2, 2, 0,
       doc: /* Remove FN from the state-handler list of HANDLE.  */)
  (Lisp_Object handle, Lisp_Object fn)
{
  cmacs_audio_stream_remove_state_handler (ca_lookup_or_error (handle), fn);
  return Qt;
}

DEFUN ("cmacs-audio-add-level-handler", Fcmacs_audio_add_level_handler,
       Scmacs_audio_add_level_handler, 2, 2, 0,
       doc: /* Register FN to be called as (FN HANDLE PEAK-DB RMS-DB)
for level-meter messages on HANDLE.  */)
  (Lisp_Object handle, Lisp_Object fn)
{
  cmacs_audio_stream_add_level_handler (ca_lookup_or_error (handle), fn);
  return Qt;
}

DEFUN ("cmacs-audio-remove-level-handler", Fcmacs_audio_remove_level_handler,
       Scmacs_audio_remove_level_handler, 2, 2, 0,
       doc: /* Remove FN from the level-handler list of HANDLE.  */)
  (Lisp_Object handle, Lisp_Object fn)
{
  cmacs_audio_stream_remove_level_handler (ca_lookup_or_error (handle), fn);
  return Qt;
}

DEFUN ("cmacs-audio-list", Fcmacs_audio_list,
       Scmacs_audio_list, 0, 0, 0,
       doc: /* Return a list of all live cmacs-audio stream handles.  */)
  (void)
{
  GList *hs = cmacs_audio_registry_handles ();
  Lisp_Object out = Qnil;
  for (GList *l = hs; l; l = l->next)
    {
      uint64_t *h = l->data;
      out = Fcons (make_int ((EMACS_INT) *h), out);
      g_free (h);
    }
  g_list_free (hs);
  return out;
}

/* ====================================================================
 * Registration
 * ==================================================================== */

void syms_of_cmacs_audio_defuns (void);
void
syms_of_cmacs_audio_defuns (void)
{
  DEFSYM (QCsource,        ":source");
  DEFSYM (QCdevice,        ":device");
  DEFSYM (QCrate,          ":rate");
  DEFSYM (QCchannels,      ":channels");
  DEFSYM (QClevel_meter,   ":level-meter");

  DEFSYM (Qcmacs_audio_error, "cmacs-audio-error");
  Fput (Qcmacs_audio_error, Qerror_conditions,
        list2 (Qcmacs_audio_error, Qerror));
  Fput (Qcmacs_audio_error, Qerror_message,
        build_string ("CMacs audio error"));

  defsubr (&Scmacs_audio_supported_p);
  defsubr (&Scmacs_audio__capture_open_1);
  defsubr (&Scmacs_audio__playback_open_file_1);
  defsubr (&Scmacs_audio__playback_open_pcm_1);
  defsubr (&Scmacs_audio_close);
  defsubr (&Scmacs_audio_start);
  defsubr (&Scmacs_audio_stop);
  defsubr (&Scmacs_audio_pause);
  defsubr (&Scmacs_audio_seek);
  defsubr (&Scmacs_audio_position);
  defsubr (&Scmacs_audio_state);
  defsubr (&Scmacs_audio_read_pcm);
  defsubr (&Scmacs_audio_push_pcm);
  defsubr (&Scmacs_audio_write_file);
  defsubr (&Scmacs_audio_level);
  defsubr (&Scmacs_audio_set_volume);
  defsubr (&Scmacs_audio_set_mute);
  defsubr (&Scmacs_audio_attach_buffer);
  defsubr (&Scmacs_audio_attach_frame);
  defsubr (&Scmacs_audio_detach);
  defsubr (&Scmacs_audio_waveform_svg);
  defsubr (&Scmacs_audio_add_state_handler);
  defsubr (&Scmacs_audio_remove_state_handler);
  defsubr (&Scmacs_audio_add_level_handler);
  defsubr (&Scmacs_audio_remove_level_handler);
  defsubr (&Scmacs_audio_list);
}

#endif /* HAVE_CMACS_AUDIO */
