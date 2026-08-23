/* cmacs-audio-stream.c --- GStreamer audio capture and playback streams.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pipeline shapes:
 *   CAPTURE:   pipewiresrc|pulsesrc ! audioconvert ! audioresample
 *              ! capsfilter(audio/x-raw,format=S16LE,channels=N,rate=R)
 *              [ ! level (when enabled) ]
 *              ! appsink (emit-signals=t, max-buffers=4, drop=true)
 *
 *   PLAYBACK-FILE: playbin uri=URI audio-sink=(autoaudiosink)
 *
 *   PLAYBACK-PCM:  appsrc(caps=audio/x-raw,S16LE,N,R) ! audioconvert
 *                  ! audioresample ! volume ! autoaudiosink
 *
 * GMainContext attachment is identical to cmacs-video:
 *   gst_bus_create_watch + g_source_attach (cmacs_glib_get_context()).
 * Never gst_bus_add_watch (default context).
 *
 * Per-stream Lisp_Objects (state callbacks, anchor markers, level
 * callbacks) live in a single staticpro'd hash table keyed by handle
 * so GC roots remain valid across teardown.
 */

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "cmacs-audio-stream.h"
#include "cmacs-audio-registry.h"

#include "lisp.h"
#include "buffer.h"
#include "frame.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/audio/audio.h>

#include <math.h>
#include <string.h>

/* --- Lisp state hash (staticpro'd) ------------------------------------ */

static Lisp_Object cmacs_audio__lisp_state;
static gboolean    cmacs_audio__lisp_state_init_done;
static Lisp_Object QCcallbacks, QCanchor_buffer, QCanchor_marker, QClevel_callbacks;

static void
cmacs_audio__lisp_state_ensure (void)
{
  if (cmacs_audio__lisp_state_init_done)
    return;
  cmacs_audio__lisp_state_init_done = true;
  cmacs_audio__lisp_state = CALLN (Fmake_hash_table, QCtest, Qeql);
  staticpro (&cmacs_audio__lisp_state);
}

static Lisp_Object
cmacs_audio__lisp_get (uint64_t handle)
{
  cmacs_audio__lisp_state_ensure ();
  Lisp_Object key = make_uint (handle);
  return Fgethash (key, cmacs_audio__lisp_state, Qnil);
}

static void
cmacs_audio__lisp_put (uint64_t handle, Lisp_Object plist)
{
  cmacs_audio__lisp_state_ensure ();
  Lisp_Object key = make_uint (handle);
  Fputhash (key, plist, cmacs_audio__lisp_state);
}

static void
cmacs_audio__lisp_remove (uint64_t handle)
{
  if (!cmacs_audio__lisp_state_init_done)
    return;
  Lisp_Object key = make_uint (handle);
  Fremhash (key, cmacs_audio__lisp_state);
}

/* --- Error log helpers ------------------------------------------------ */

#define ERROR_LOG_MAX 32
typedef struct {
  gint64  ts_us;
  guint32 domain;
  gint    code;
  gchar  *msg;        /* owned */
  gchar  *debug;      /* owned */
} CmacsAudioErr;

static void
cmacs_audio__error_log_push (CmacsAudioStream *s, guint32 domain,
                             gint code, const char *msg, const char *debug)
{
  if (!s->error_log)
    s->error_log = g_array_sized_new (FALSE, FALSE, sizeof (CmacsAudioErr),
                                      ERROR_LOG_MAX);
  if (s->error_log->len >= ERROR_LOG_MAX)
    {
      CmacsAudioErr *front = &g_array_index (s->error_log, CmacsAudioErr, 0);
      g_free (front->msg);
      g_free (front->debug);
      g_array_remove_index (s->error_log, 0);
    }
  CmacsAudioErr e = { g_get_monotonic_time (), domain, code,
                      g_strdup (msg ? msg : ""),
                      g_strdup (debug ? debug : "") };
  g_array_append_val (s->error_log, e);
}

static void
cmacs_audio__error_log_free (CmacsAudioStream *s)
{
  if (!s->error_log)
    return;
  for (guint i = 0; i < s->error_log->len; i++)
    {
      CmacsAudioErr *e = &g_array_index (s->error_log, CmacsAudioErr, i);
      g_free (e->msg);
      g_free (e->debug);
    }
  g_array_free (s->error_log, TRUE);
  s->error_log = NULL;
}

/* --- State transitions ------------------------------------------------ */

Lisp_Object
cmacs_audio_state_symbol (CmacsAudioState st)
{
  switch (st)
    {
    case CMACS_AUDIO_STATE_INITIALIZING: return intern ("initializing");
    case CMACS_AUDIO_STATE_READY:        return intern ("ready");
    case CMACS_AUDIO_STATE_PLAYING:      return intern ("playing");
    case CMACS_AUDIO_STATE_PAUSED:       return intern ("paused");
    case CMACS_AUDIO_STATE_EOS:          return intern ("eos");
    case CMACS_AUDIO_STATE_ERROR:        return intern ("error");
    case CMACS_AUDIO_STATE_CLOSED:       return intern ("closed");
    }
  return Qnil;
}

Lisp_Object
cmacs_audio_source_symbol (CmacsAudioSourceKind k)
{
  switch (k)
    {
    case CMACS_AUDIO_SOURCE_AUTO:         return intern ("auto");
    case CMACS_AUDIO_SOURCE_PIPEWIRE:     return intern ("pipewire");
    case CMACS_AUDIO_SOURCE_PULSE:        return intern ("pulse");
    case CMACS_AUDIO_SOURCE_AUDIOTESTSRC: return intern ("test");
    case CMACS_AUDIO_SOURCE_COREAUDIO:    return intern ("coreaudio");
    }
  return intern ("auto");
}

CmacsAudioSourceKind
cmacs_audio_source_from_symbol (Lisp_Object sym)
{
  if (NILP (sym) || EQ (sym, intern ("auto"))) return CMACS_AUDIO_SOURCE_AUTO;
  if (EQ (sym, intern ("pipewire")))           return CMACS_AUDIO_SOURCE_PIPEWIRE;
  if (EQ (sym, intern ("pulse")))              return CMACS_AUDIO_SOURCE_PULSE;
  if (EQ (sym, intern ("test")))               return CMACS_AUDIO_SOURCE_AUDIOTESTSRC;
  if (EQ (sym, intern ("coreaudio")))          return CMACS_AUDIO_SOURCE_COREAUDIO;
  return CMACS_AUDIO_SOURCE_AUTO;
}

static void
cmacs_audio__fire_state_handlers (CmacsAudioStream *s)
{
  if (!s) return;
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (NILP (plist)) return;
  Lisp_Object cbs = plist_get (plist, QCcallbacks);
  if (NILP (cbs)) return;
  Lisp_Object handle = make_uint (s->handle);
  Lisp_Object state  = cmacs_audio_state_symbol (s->state);
  for (Lisp_Object tail = cbs; CONSP (tail); tail = XCDR (tail))
    cmacs_dispatch_safe_call2 (XCAR (tail), handle, state);
}

static gboolean
cmacs_audio__state_idle (gpointer user)
{
  CmacsAudioStream *s = user;
  cmacs_audio__fire_state_handlers (s);
  return G_SOURCE_REMOVE;
}

static void
cmacs_audio__set_state (CmacsAudioStream *s, CmacsAudioState newst)
{
  if (s->state == newst)
    return;
  s->state = newst;
  g_main_context_invoke (cmacs_glib_get_context (),
                         cmacs_audio__state_idle, s);
}

/* --- Bus watch -------------------------------------------------------- */

static gboolean
cmacs_audio__on_bus_message (GstBus *bus, GstMessage *msg, gpointer user)
{
  (void) bus;
  CmacsAudioStream *s = user;
  if (!s || s->state == CMACS_AUDIO_STATE_CLOSED)
    return G_SOURCE_CONTINUE;

  switch (GST_MESSAGE_TYPE (msg))
    {
    case GST_MESSAGE_ERROR:
      {
        GError *err = NULL;
        gchar  *dbg = NULL;
        gst_message_parse_error (msg, &err, &dbg);
        cmacs_audio__error_log_push (s,
                                     err ? err->domain : 0,
                                     err ? err->code : 0,
                                     err ? err->message : "(no message)",
                                     dbg);
        cmacs_audio__set_state (s, CMACS_AUDIO_STATE_ERROR);
        if (err) g_error_free (err);
        g_free (dbg);
      }
      break;

    case GST_MESSAGE_EOS:
      cmacs_audio__set_state (s, CMACS_AUDIO_STATE_EOS);
      if (s->loop_p)
        {
          gst_element_seek_simple (s->pipeline, GST_FORMAT_TIME,
                                   GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
                                   0);
          gst_element_set_state (s->pipeline, GST_STATE_PLAYING);
        }
      break;

    case GST_MESSAGE_STATE_CHANGED:
      if (GST_MESSAGE_SRC (msg) == GST_OBJECT (s->pipeline))
        {
          GstState old, new_st, pend;
          gst_message_parse_state_changed (msg, &old, &new_st, &pend);
          switch (new_st)
            {
            case GST_STATE_PLAYING: cmacs_audio__set_state (s, CMACS_AUDIO_STATE_PLAYING); break;
            case GST_STATE_PAUSED:  cmacs_audio__set_state (s, CMACS_AUDIO_STATE_PAUSED);  break;
            case GST_STATE_READY:   cmacs_audio__set_state (s, CMACS_AUDIO_STATE_READY);   break;
            default: break;
            }
        }
      break;

    case GST_MESSAGE_ELEMENT:
      {
        const GstStructure *st = gst_message_get_structure (msg);
        if (st && gst_structure_has_name (st, "level"))
          {
            const GValue *rms_arr = gst_structure_get_value (st, "rms");
            const GValue *peak_arr = gst_structure_get_value (st, "peak");
            if (rms_arr && peak_arr
                && GST_VALUE_HOLDS_ARRAY (rms_arr)
                && GST_VALUE_HOLDS_ARRAY (peak_arr)
                && gst_value_array_get_size (rms_arr) > 0
                && gst_value_array_get_size (peak_arr) > 0)
              {
                s->last_rms_db  = g_value_get_double (gst_value_array_get_value (rms_arr, 0));
                s->last_peak_db = g_value_get_double (gst_value_array_get_value (peak_arr, 0));
                s->last_level_us = g_get_monotonic_time ();
                /* Fire level handlers on main thread. */
                Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
                if (!NILP (plist))
                  {
                    Lisp_Object cbs = plist_get (plist, QClevel_callbacks);
                    if (!NILP (cbs))
                      {
                        Lisp_Object handle = make_uint (s->handle);
                        Lisp_Object peak   = make_float (s->last_peak_db);
                        Lisp_Object rms    = make_float (s->last_rms_db);
                        for (Lisp_Object tail = cbs; CONSP (tail); tail = XCDR (tail))
                          cmacs_dispatch_safe_call3 (XCAR (tail),
                                                     handle, peak, rms);
                      }
                  }
              }
          }
      }
      break;

    default:
      break;
    }
  return G_SOURCE_CONTINUE;
}

static gboolean
cmacs_audio__attach_bus_watch (CmacsAudioStream *s)
{
  s->bus = gst_pipeline_get_bus (GST_PIPELINE (s->pipeline));
  if (!s->bus) return FALSE;
  s->bus_watch = gst_bus_create_watch (s->bus);
  if (!s->bus_watch) return FALSE;
  g_source_set_callback (s->bus_watch,
                         G_SOURCE_FUNC (cmacs_audio__on_bus_message),
                         /* G_SOURCE_FUNC, not a plain cast: a bus watch
                            callback really is a GstBusFunc, and casting it
                            straight to GSourceFunc is a cast between
                            incompatible function types.  The macro routes
                            it through void(*)(void), which is the form
                            GLib defines for exactly this. */
                         s, NULL);
  g_source_attach (s->bus_watch, cmacs_glib_get_context ());
  g_source_unref (s->bus_watch);
  return TRUE;
}

/* --- Appsink new-sample (CAPTURE) ------------------------------------- */

static GstFlowReturn
cmacs_audio__on_new_sample (GstAppSink *sink, gpointer user)
{
  CmacsAudioStream *s = user;
  GstSample *sample = gst_app_sink_pull_sample (sink);
  if (!sample) return GST_FLOW_EOS;
  GstBuffer *buf = gst_sample_get_buffer (sample);
  if (!buf) { gst_sample_unref (sample); return GST_FLOW_OK; }
  GstMapInfo info;
  if (!gst_buffer_map (buf, &info, GST_MAP_READ))
    { gst_sample_unref (sample); return GST_FLOW_ERROR; }

  guint sample_bytes = sizeof (int16_t) * s->channels;
  guint n_frames = info.size / sample_bytes;

  g_mutex_lock (&s->frame_mtx);
  guint avail = s->capacity_frames - s->back_fill;
  if (n_frames > avail) n_frames = avail;
  if (n_frames > 0)
    {
      memcpy (s->back_pcm + s->back_fill * s->channels,
              info.data,
              n_frames * sample_bytes);
      s->back_fill += n_frames;
      s->frames_processed += n_frames;
      s->last_sample_us = g_get_monotonic_time ();
      s->waveform_dirty = TRUE;
    }
  /* When back is full, swap. */
  if (s->back_fill >= s->capacity_frames)
    {
      int16_t *tmp = s->front_pcm;
      s->front_pcm = s->back_pcm;
      s->front_fill = s->back_fill;
      s->back_pcm = tmp;
      s->back_fill = 0;
    }
  g_mutex_unlock (&s->frame_mtx);

  gst_buffer_unmap (buf, &info);
  gst_sample_unref (sample);
  return GST_FLOW_OK;
}

/* --- Pipeline construction (CAPTURE) ---------------------------------- */

static const char *
cmacs_audio__factory_for_kind (CmacsAudioSourceKind k)
{
  switch (k)
    {
    case CMACS_AUDIO_SOURCE_PIPEWIRE:     return "pipewiresrc";
    case CMACS_AUDIO_SOURCE_PULSE:        return "pulsesrc";
    case CMACS_AUDIO_SOURCE_AUDIOTESTSRC: return "audiotestsrc";
    case CMACS_AUDIO_SOURCE_COREAUDIO:    return "osxaudiosrc";
    default: break;
    }
  return NULL;
}

static GstElement *
cmacs_audio__make_capture_source (CmacsAudioSourceKind requested,
                                  const char *device,
                                  CmacsAudioSourceKind *out_chosen)
{
  /* AUTO: try pipewiresrc, fall back to pulsesrc. */
  if (requested == CMACS_AUDIO_SOURCE_AUTO)
    {
      GstElement *e = gst_element_factory_make ("pipewiresrc", "cmacs-audio-src");
      if (e) { *out_chosen = CMACS_AUDIO_SOURCE_PIPEWIRE; }
      else   { e = gst_element_factory_make ("pulsesrc", "cmacs-audio-src");
               if (e) *out_chosen = CMACS_AUDIO_SOURCE_PULSE; }
      if (e && device)
        g_object_set (e, "device", device, NULL);
      return e;
    }
  const char *fac = cmacs_audio__factory_for_kind (requested);
  if (!fac) return NULL;
  GstElement *e = gst_element_factory_make (fac, "cmacs-audio-src");
  if (!e) return NULL;
  *out_chosen = requested;
  if (device && requested != CMACS_AUDIO_SOURCE_AUDIOTESTSRC)
    g_object_set (e, "device", device, NULL);
  return e;
}

CmacsAudioStream *
cmacs_audio_stream_new_capture (CmacsAudioSourceKind kind, const char *device,
                                int rate, int channels, gboolean enable_level,
                                GError **error)
{
  CmacsAudioStream *s = g_new0 (CmacsAudioStream, 1);
  s->mode = CMACS_AUDIO_MODE_CAPTURE;
  s->source_kind = kind;
  s->device = device ? g_strdup (device) : NULL;
  s->sample_rate = rate > 0 ? rate : 16000;
  s->channels = channels > 0 ? channels : 1;
  s->bit_depth = 16;
  s->level_meter_enabled = enable_level;
  s->volume = 1.0;
  s->state = CMACS_AUDIO_STATE_INITIALIZING;
  g_mutex_init (&s->frame_mtx);
  g_mutex_init (&s->cb_mtx);
  /* 5 seconds of front + back buffers. */
  s->capacity_frames = s->sample_rate * 5;
  s->front_pcm = g_malloc0_n (s->capacity_frames * s->channels, sizeof (int16_t));
  s->back_pcm  = g_malloc0_n (s->capacity_frames * s->channels, sizeof (int16_t));

  CmacsAudioSourceKind chosen = kind;
  GstElement *src = cmacs_audio__make_capture_source (kind, device, &chosen);
  if (!src)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-audio: no usable capture source factory (tried %s)",
                   cmacs_audio__factory_for_kind (kind) ?: "auto");
      cmacs_audio_stream_destroy (s);
      return NULL;
    }
  s->source_kind = chosen;

  GstElement *convert    = gst_element_factory_make ("audioconvert",  NULL);
  GstElement *resample   = gst_element_factory_make ("audioresample", NULL);
  GstElement *capsfilter = gst_element_factory_make ("capsfilter",    NULL);
  GstElement *level      = enable_level
    ? gst_element_factory_make ("level", NULL) : NULL;
  GstElement *sink       = gst_element_factory_make ("appsink", "cmacs-audio-sink");

  if (!convert || !resample || !capsfilter || !sink
      || (enable_level && !level))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
                   "cmacs-audio: required GStreamer elements missing "
                   "(audioconvert/audioresample/capsfilter/appsink/level)");
      g_clear_object (&src);
      g_clear_object (&convert);
      g_clear_object (&resample);
      g_clear_object (&capsfilter);
      g_clear_object (&level);
      g_clear_object (&sink);
      cmacs_audio_stream_destroy (s);
      return NULL;
    }

  GstCaps *caps = gst_caps_new_simple ("audio/x-raw",
                                       "format",   G_TYPE_STRING, "S16LE",
                                       "channels", G_TYPE_INT, s->channels,
                                       "rate",     G_TYPE_INT, s->sample_rate,
                                       "layout",   G_TYPE_STRING, "interleaved",
                                       NULL);
  g_object_set (capsfilter, "caps", caps, NULL);
  gst_caps_unref (caps);

  g_object_set (sink,
                "emit-signals", TRUE,
                "max-buffers",  (guint) 4,
                "drop",         TRUE,
                "sync",         FALSE,
                NULL);
  g_signal_connect (sink, "new-sample",
                    G_CALLBACK (cmacs_audio__on_new_sample), s);

  if (level)
    g_object_set (level,
                  "interval",         (guint64) 100000000 /* 100 ms */,
                  "post-messages",    TRUE,
                  NULL);

  s->pipeline = gst_pipeline_new ("cmacs-audio-capture");
  if (level)
    {
      gst_bin_add_many (GST_BIN (s->pipeline),
                        src, convert, resample, capsfilter, level, sink, NULL);
      if (!gst_element_link_many (src, convert, resample, capsfilter,
                                  level, sink, NULL))
        {
          g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_NEGOTIATION,
                       "cmacs-audio: capture pipeline link failed");
          cmacs_audio_stream_destroy (s);
          return NULL;
        }
      s->level_elem = level;
    }
  else
    {
      gst_bin_add_many (GST_BIN (s->pipeline),
                        src, convert, resample, capsfilter, sink, NULL);
      if (!gst_element_link_many (src, convert, resample, capsfilter,
                                  sink, NULL))
        {
          g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_NEGOTIATION,
                       "cmacs-audio: capture pipeline link failed");
          cmacs_audio_stream_destroy (s);
          return NULL;
        }
    }
  s->appsink = sink;

  if (!cmacs_audio__attach_bus_watch (s))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-audio: failed to attach bus watch");
      cmacs_audio_stream_destroy (s);
      return NULL;
    }

  cmacs_audio_registry_insert (s);
  s->state = CMACS_AUDIO_STATE_READY;
  return s;
}

/* --- PLAYBACK (file via playbin) -------------------------------------- */

CmacsAudioStream *
cmacs_audio_stream_new_playback_file (const char *uri, GError **error)
{
  if (!uri || !*uri)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-audio: playback requires a URI");
      return NULL;
    }
  CmacsAudioStream *s = g_new0 (CmacsAudioStream, 1);
  s->mode = CMACS_AUDIO_MODE_PLAYBACK;
  s->uri = g_strdup (uri);
  s->sample_rate = 0;     /* file-driven */
  s->channels = 0;        /* file-driven */
  s->volume = 1.0;
  s->state = CMACS_AUDIO_STATE_INITIALIZING;
  g_mutex_init (&s->frame_mtx);
  g_mutex_init (&s->cb_mtx);

  GstElement *playbin = gst_element_factory_make ("playbin3", "cmacs-audio-play");
  if (!playbin)
    playbin = gst_element_factory_make ("playbin", "cmacs-audio-play");
  if (!playbin)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
                   "cmacs-audio: playbin3/playbin element not available");
      cmacs_audio_stream_destroy (s);
      return NULL;
    }
  /* Suppress video stream entirely (audio-only). */
  GstElement *vsink = gst_element_factory_make ("fakesink", "cmacs-audio-fakevideo");
  if (vsink)
    {
      g_object_set (vsink, "sync", FALSE, NULL);
      g_object_set (playbin, "video-sink", vsink, NULL);
    }
  g_object_set (playbin, "uri", uri, "volume", s->volume, NULL);

  s->pipeline = playbin;

  if (!cmacs_audio__attach_bus_watch (s))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-audio: failed to attach bus watch");
      cmacs_audio_stream_destroy (s);
      return NULL;
    }
  cmacs_audio_registry_insert (s);
  s->state = CMACS_AUDIO_STATE_READY;
  return s;
}

/* --- PLAYBACK (PCM via appsrc) ---------------------------------------- */

CmacsAudioStream *
cmacs_audio_stream_new_playback_pcm (int rate, int channels, GError **error)
{
  CmacsAudioStream *s = g_new0 (CmacsAudioStream, 1);
  s->mode = CMACS_AUDIO_MODE_PLAYBACK;
  s->sample_rate = rate > 0 ? rate : 22050;
  s->channels = channels > 0 ? channels : 1;
  s->bit_depth = 16;
  s->volume = 1.0;
  s->state = CMACS_AUDIO_STATE_INITIALIZING;
  g_mutex_init (&s->frame_mtx);
  g_mutex_init (&s->cb_mtx);
  s->capacity_frames = s->sample_rate * 2;
  s->front_pcm = g_malloc0_n (s->capacity_frames * s->channels, sizeof (int16_t));
  s->back_pcm  = g_malloc0_n (s->capacity_frames * s->channels, sizeof (int16_t));

  GstElement *src      = gst_element_factory_make ("appsrc", "cmacs-audio-src");
  GstElement *convert  = gst_element_factory_make ("audioconvert", NULL);
  GstElement *resample = gst_element_factory_make ("audioresample", NULL);
  GstElement *vol      = gst_element_factory_make ("volume", NULL);
  GstElement *sink     = gst_element_factory_make ("autoaudiosink", NULL);

  if (!src || !convert || !resample || !vol || !sink)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
                   "cmacs-audio: required playback elements missing");
      g_clear_object (&src);
      g_clear_object (&convert);
      g_clear_object (&resample);
      g_clear_object (&vol);
      g_clear_object (&sink);
      cmacs_audio_stream_destroy (s);
      return NULL;
    }
  GstCaps *caps = gst_caps_new_simple ("audio/x-raw",
                                       "format",   G_TYPE_STRING, "S16LE",
                                       "channels", G_TYPE_INT, s->channels,
                                       "rate",     G_TYPE_INT, s->sample_rate,
                                       "layout",   G_TYPE_STRING, "interleaved",
                                       NULL);
  g_object_set (src,
                "caps", caps,
                "format", GST_FORMAT_TIME,
                "is-live", FALSE,
                "do-timestamp", TRUE,
                NULL);
  gst_caps_unref (caps);
  g_object_set (vol, "volume", s->volume, NULL);

  s->pipeline = gst_pipeline_new ("cmacs-audio-playback-pcm");
  gst_bin_add_many (GST_BIN (s->pipeline), src, convert, resample, vol, sink, NULL);
  if (!gst_element_link_many (src, convert, resample, vol, sink, NULL))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_NEGOTIATION,
                   "cmacs-audio: playback-pcm pipeline link failed");
      cmacs_audio_stream_destroy (s);
      return NULL;
    }
  s->appsrc = src;
  s->volume_elem = vol;

  if (!cmacs_audio__attach_bus_watch (s))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-audio: failed to attach bus watch");
      cmacs_audio_stream_destroy (s);
      return NULL;
    }
  cmacs_audio_registry_insert (s);
  s->state = CMACS_AUDIO_STATE_READY;
  return s;
}

/* --- Destroy (load-bearing order, mirrors cmacs-video) ---------------- */

void
cmacs_audio_stream_destroy (CmacsAudioStream *s)
{
  if (!s) return;
  s->state = CMACS_AUDIO_STATE_CLOSED;

  if (s->bus_watch)
    {
      g_source_destroy (s->bus_watch);
      s->bus_watch = NULL;
    }

  if (s->pipeline)
    {
      gst_element_set_state (s->pipeline, GST_STATE_NULL);
      /* Drain bus to release refs. */
      if (s->bus)
        {
          GstMessage *m;
          while ((m = gst_bus_pop (s->bus)))
            gst_message_unref (m);
        }
    }

  if (s->waveform_surface)
    {
      cairo_surface_destroy (s->waveform_surface);
      s->waveform_surface = NULL;
    }

  g_free (s->front_pcm);
  g_free (s->back_pcm);

  if (s->bus)      { gst_object_unref (s->bus); s->bus = NULL; }
  if (s->pipeline) { gst_object_unref (s->pipeline); s->pipeline = NULL; }

  g_free (s->uri);
  g_free (s->device);
  cmacs_audio__error_log_free (s);
  g_mutex_clear (&s->frame_mtx);
  g_mutex_clear (&s->cb_mtx);

  cmacs_audio__lisp_remove (s->handle);
  g_free (s);
}

/* --- State control ---------------------------------------------------- */

void cmacs_audio_stream_start (CmacsAudioStream *s)
{
  if (s && s->pipeline) gst_element_set_state (s->pipeline, GST_STATE_PLAYING);
}
void cmacs_audio_stream_pause (CmacsAudioStream *s)
{
  if (s && s->pipeline) gst_element_set_state (s->pipeline, GST_STATE_PAUSED);
}
void cmacs_audio_stream_stop  (CmacsAudioStream *s)
{
  if (s && s->pipeline) gst_element_set_state (s->pipeline, GST_STATE_READY);
}

void
cmacs_audio_stream_seek_ns (CmacsAudioStream *s, gint64 pos_ns)
{
  if (!s || !s->pipeline) return;
  gst_element_seek_simple (s->pipeline, GST_FORMAT_TIME,
                           GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
                           pos_ns);
}

gint64
cmacs_audio_stream_position_ns (CmacsAudioStream *s)
{
  gint64 pos = -1;
  if (s && s->pipeline)
    gst_element_query_position (s->pipeline, GST_FORMAT_TIME, &pos);
  return pos;
}

gint64
cmacs_audio_stream_duration_ns (CmacsAudioStream *s)
{
  gint64 dur = -1;
  if (s && s->pipeline)
    gst_element_query_duration (s->pipeline, GST_FORMAT_TIME, &dur);
  return dur;
}

void
cmacs_audio_stream_set_volume (CmacsAudioStream *s, double v)
{
  if (!s) return;
  if (v < 0.0) v = 0.0; if (v > 1.0) v = 1.0;
  s->volume = v;
  if (s->volume_elem)
    g_object_set (s->volume_elem, "volume", v, NULL);
  else if (s->pipeline && s->mode == CMACS_AUDIO_MODE_PLAYBACK)
    g_object_set (s->pipeline, "volume", v, NULL);
}

void
cmacs_audio_stream_set_mute (CmacsAudioStream *s, gboolean m)
{
  if (!s) return;
  s->muted = m;
  if (s->volume_elem)
    g_object_set (s->volume_elem, "mute", (gboolean) m, NULL);
  else if (s->pipeline && s->mode == CMACS_AUDIO_MODE_PLAYBACK)
    g_object_set (s->pipeline, "mute", (gboolean) m, NULL);
}

/* --- PCM drain / push ------------------------------------------------- */

guint
cmacs_audio_stream_drain_pcm (CmacsAudioStream *s, int16_t *out, guint n_frames)
{
  if (!s || s->mode != CMACS_AUDIO_MODE_CAPTURE || !out) return 0;
  g_mutex_lock (&s->frame_mtx);
  guint chans = s->channels;
  guint total_avail = s->front_fill + s->back_fill;
  guint take = total_avail < n_frames ? total_avail : n_frames;

  /* Drain in order: front (full buffer, oldest) then back (partial, newest).
   * The streaming thread fills back; when back is full, back<->front swap
   * (back becomes the new full snapshot, front becomes empty back).  For
   * sub-buffer-length recordings, front is empty and all samples live in
   * back -- we must include both to recover any audio at all. */
  guint take_front = take < s->front_fill ? take : s->front_fill;
  guint take_back  = take - take_front;

  if (take_front > 0)
    memcpy (out, s->front_pcm, take_front * chans * sizeof (int16_t));
  if (take_back > 0)
    memcpy (out + take_front * chans,
            s->back_pcm,
            take_back * chans * sizeof (int16_t));

  /* Slide whatever's left in front, then in back, toward the start so
   * subsequent drains see the unread tail. */
  if (take_front < s->front_fill)
    memmove (s->front_pcm,
             s->front_pcm + take_front * chans,
             (s->front_fill - take_front) * chans * sizeof (int16_t));
  s->front_fill -= take_front;
  if (take_back < s->back_fill)
    memmove (s->back_pcm,
             s->back_pcm + take_back * chans,
             (s->back_fill - take_back) * chans * sizeof (int16_t));
  s->back_fill -= take_back;
  g_mutex_unlock (&s->frame_mtx);
  return take;
}

gboolean
cmacs_audio_stream_push_pcm (CmacsAudioStream *s, const int16_t *in, guint n_frames)
{
  if (!s || !s->appsrc || !in || n_frames == 0) return FALSE;
  gsize bytes = (gsize) n_frames * s->channels * sizeof (int16_t);
  GstBuffer *buf = gst_buffer_new_allocate (NULL, bytes, NULL);
  if (!buf) return FALSE;
  GstMapInfo info;
  gst_buffer_map (buf, &info, GST_MAP_WRITE);
  memcpy (info.data, in, bytes);
  gst_buffer_unmap (buf, &info);
  GstFlowReturn ret = gst_app_src_push_buffer (GST_APP_SRC (s->appsrc), buf);
  return ret == GST_FLOW_OK;
}

/* --- WAV writer (minimal RIFF/PCM, captures front buffer + flushes
       back into front beforehand) -------------------------------------- */

gboolean
cmacs_audio_stream_write_wav (CmacsAudioStream *s, const char *path, GError **err)
{
  if (!s || s->mode != CMACS_AUDIO_MODE_CAPTURE)
    {
      g_set_error (err, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                   "cmacs-audio: write-wav only valid on capture streams");
      return FALSE;
    }
  g_mutex_lock (&s->frame_mtx);
  guint chans       = s->channels;
  int   rate        = s->sample_rate;
  guint front_n     = s->front_fill;
  guint back_n      = s->back_fill;
  guint nframes     = front_n + back_n;
  gsize sample_bytes = (gsize) chans * sizeof (int16_t);
  gsize dsize       = (gsize) nframes * sample_bytes;
  /* Always allocate at least 1 byte so g_malloc never returns NULL
   * for zero-size requests (g_malloc(0) is well-defined but g_free
   * of the result is too -- keep the API simple). */
  guint8 *copy = g_malloc (dsize > 0 ? dsize : 1);
  if (front_n)
    memcpy (copy, s->front_pcm, front_n * sample_bytes);
  if (back_n)
    memcpy (copy + front_n * sample_bytes,
            s->back_pcm, back_n * sample_bytes);
  g_mutex_unlock (&s->frame_mtx);

  FILE *f = fopen (path, "wb");
  if (!f) { g_free (copy);
            g_set_error (err, G_FILE_ERROR, g_file_error_from_errno (errno),
                         "cmacs-audio: open %s: %s", path, g_strerror (errno));
            return FALSE; }
  guint32 byte_rate   = (guint32) rate * chans * 2;
  guint16 block_align = chans * 2;
  guint32 chunk_size  = 36 + dsize;
  fwrite ("RIFF", 1, 4, f);
  fwrite (&chunk_size, 4, 1, f);
  fwrite ("WAVEfmt ", 1, 8, f);
  guint32 fmt_chunk = 16;  fwrite (&fmt_chunk, 4, 1, f);
  guint16 fmt = 1;         fwrite (&fmt, 2, 1, f);
  guint16 c   = chans;     fwrite (&c, 2, 1, f);
  guint32 r   = rate;      fwrite (&r, 4, 1, f);
  fwrite (&byte_rate, 4, 1, f);
  fwrite (&block_align, 2, 1, f);
  guint16 bps = 16;        fwrite (&bps, 2, 1, f);
  fwrite ("data", 1, 4, f);
  guint32 dsize32 = (guint32) dsize;
  fwrite (&dsize32, 4, 1, f);
  if (dsize) fwrite (copy, 1, dsize, f);
  fclose (f);
  g_free (copy);
  return TRUE;
}

/* --- Anchoring -------------------------------------------------------- */

void
cmacs_audio_stream_attach_buffer (CmacsAudioStream *s, Lisp_Object marker)
{
  if (!s || !MARKERP (marker)) return;
  s->standalone_frame = NULL;
  Lisp_Object buf = Fmarker_buffer (marker);
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (NILP (plist)) plist = Qnil;
  plist = plist_put (plist, QCanchor_buffer, buf);
  plist = plist_put (plist, QCanchor_marker, marker);
  cmacs_audio__lisp_put (s->handle, plist);
}

void
cmacs_audio_stream_attach_frame (CmacsAudioStream *s, struct frame *f,
                                 int x, int y, int w, int h)
{
  if (!s || !f) return;
  s->standalone_frame = f;
  s->standalone_x = x;  s->standalone_y = y;
  s->standalone_w = w;  s->standalone_h = h;
  cmacs_audio_registry_attach_frame (f, s);
}

void
cmacs_audio_stream_detach (CmacsAudioStream *s)
{
  if (!s) return;
  if (s->standalone_frame)
    {
      cmacs_audio_registry_detach_frame (s->standalone_frame, s);
      s->standalone_frame = NULL;
    }
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (!NILP (plist))
    {
      plist = plist_put (plist, QCanchor_buffer, Qnil);
      plist = plist_put (plist, QCanchor_marker, Qnil);
      cmacs_audio__lisp_put (s->handle, plist);
    }
}

Lisp_Object
cmacs_audio_stream_anchor_buffer (CmacsAudioStream *s)
{
  if (!s) return Qnil;
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (NILP (plist)) return Qnil;
  return plist_get (plist, QCanchor_buffer);
}

Lisp_Object
cmacs_audio_stream_anchor_marker (CmacsAudioStream *s)
{
  if (!s) return Qnil;
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (NILP (plist)) return Qnil;
  return plist_get (plist, QCanchor_marker);
}

/* --- Callback registration -------------------------------------------- */

static void
cmacs_audio__add_handler (CmacsAudioStream *s, Lisp_Object fn,
                          Lisp_Object kw)
{
  if (!s) return;
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (NILP (plist)) plist = Qnil;
  Lisp_Object cbs = plist_get (plist, kw);
  cbs = Fcons (fn, cbs);
  plist = plist_put (plist, kw, cbs);
  cmacs_audio__lisp_put (s->handle, plist);
}

static void
cmacs_audio__remove_handler (CmacsAudioStream *s, Lisp_Object fn,
                             Lisp_Object kw)
{
  if (!s) return;
  Lisp_Object plist = cmacs_audio__lisp_get (s->handle);
  if (NILP (plist)) return;
  Lisp_Object cbs = plist_get (plist, kw);
  cbs = Fdelq (fn, cbs);
  plist = plist_put (plist, kw, cbs);
  cmacs_audio__lisp_put (s->handle, plist);
}

void cmacs_audio_stream_add_state_handler    (CmacsAudioStream *s, Lisp_Object fn)
{ cmacs_audio__add_handler (s, fn, QCcallbacks); }
void cmacs_audio_stream_remove_state_handler (CmacsAudioStream *s, Lisp_Object fn)
{ cmacs_audio__remove_handler (s, fn, QCcallbacks); }
void cmacs_audio_stream_add_level_handler    (CmacsAudioStream *s, Lisp_Object fn)
{ cmacs_audio__add_handler (s, fn, QClevel_callbacks); }
void cmacs_audio_stream_remove_level_handler (CmacsAudioStream *s, Lisp_Object fn)
{ cmacs_audio__remove_handler (s, fn, QClevel_callbacks); }

/* --- Module-internal init for keyword symbols ------------------------- */

void cmacs_audio__stream_init_symbols (void);
void
cmacs_audio__stream_init_symbols (void)
{
  QCcallbacks       = intern (":callbacks");
  QCanchor_buffer   = intern (":anchor-buffer");
  QCanchor_marker   = intern (":anchor-marker");
  QClevel_callbacks = intern (":level-callbacks");
  staticpro (&QCcallbacks);
  staticpro (&QCanchor_buffer);
  staticpro (&QCanchor_marker);
  staticpro (&QClevel_callbacks);
}

#endif /* HAVE_CMACS_AUDIO */
