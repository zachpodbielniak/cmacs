/* cmacs-video-stream.c --- GStreamer playbin3 pipeline per stream.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pipeline shape:
 *
 *   playbin3
 *     uri = <URI>
 *     video-sink = bin( videoconvert ! videoscale
 *                       ! capsfilter(video/x-raw,format=BGRA)
 *                       ! appsink emit-signals=true max-buffers=2 drop=true )
 *     audio-sink = autoaudiosink  (if audio_enabled)
 *                  fakesink sync=false (if not)
 *
 * The appsink "new-sample" callback fires on a GStreamer streaming
 * thread; we mem-copy BGRA bytes into a mutex-guarded double-buffer
 * and schedule a redraw via g_main_context_invoke on
 * cmacs_glib_get_context() so all Lisp/redraw work runs on the
 * Emacs main thread.
 *
 * The bus watch is attached via gst_bus_create_watch +
 * g_source_attach(cmacs_glib_get_context()) -- NOT
 * gst_bus_add_watch (which attaches to the default context).
 */

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "cmacs-video-stream.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include "lisp.h"
#include "frame.h"
#include "buffer.h"

#include <gst/app/gstappsink.h>
#include <gst/video/video.h>

#include <string.h>

/* ====================================================================
 * Lisp object table (GC-safe storage for per-stream Lisp_Objects)
 *
 * Storing Lisp_Object inside heap-allocated structs and staticpro-ing
 * the pointer is unsafe -- when the struct is freed, the address is
 * reused for other heap allocations and GC will scan whatever junk
 * lives there.  Instead, we keep a single Lisp hash table keyed by
 * handle, mapping to a plist of (:callbacks LIST :anchor-buffer BUF
 * :anchor-marker MK).  The hash table itself is staticpro'd once.
 * ==================================================================== */

/* Initialised to Qnil at first use via cmacs_video__lisp_state_ensure. */
static Lisp_Object cmacs_video__lisp_state;
static gboolean    cmacs_video__lisp_state_init_done = FALSE;

static void
cmacs_video__lisp_state_ensure (void)
{
  if (!cmacs_video__lisp_state_init_done)
    {
      cmacs_video__lisp_state = Qnil;
      staticpro (&cmacs_video__lisp_state);
      cmacs_video__lisp_state_init_done = TRUE;
    }
  if (NILP (cmacs_video__lisp_state))
    cmacs_video__lisp_state = CALLN (Fmake_hash_table, QCtest, Qeql);
}

static Lisp_Object
cmacs_video__lisp_get (uint64_t handle, Lisp_Object key)
{
  if (NILP (cmacs_video__lisp_state)) return Qnil;
  Lisp_Object pl = Fgethash (make_int ((EMACS_INT) handle),
                             cmacs_video__lisp_state, Qnil);
  /* Fplist_get takes (plist, prop, predicate); pass Qnil to mean
   * default eq-based comparison. */
  return Fplist_get (pl, key, Qnil);
}

static void
cmacs_video__lisp_set (uint64_t handle, Lisp_Object key, Lisp_Object val)
{
  cmacs_video__lisp_state_ensure ();
  Lisp_Object hkey = make_int ((EMACS_INT) handle);
  Lisp_Object pl = Fgethash (hkey, cmacs_video__lisp_state, Qnil);
  pl = Fplist_put (pl, key, val, Qnil);
  Fputhash (hkey, pl, cmacs_video__lisp_state);
}

static void
cmacs_video__lisp_remove (uint64_t handle)
{
  if (NILP (cmacs_video__lisp_state)) return;
  Fremhash (make_int ((EMACS_INT) handle), cmacs_video__lisp_state);
}

/* Plist keys for cmacs_video__lisp_state entries.  Interned in
 * cmacs_video__init_symbols. */
static Lisp_Object QCcv_callbacks;
static Lisp_Object QCcv_anchor_buffer;
static Lisp_Object QCcv_anchor_frame;
static Lisp_Object QCcv_anchor_marker;

/* ====================================================================
 * Forward decls
 * ==================================================================== */

static gboolean        cmacs_video__on_bus_message     (GstBus *,
                                                        GstMessage *,
                                                        gpointer);
static GstFlowReturn   cmacs_video__on_new_sample      (GstAppSink *,
                                                        gpointer);
static void            cmacs_video__on_source_setup    (GstElement *,
                                                        GstElement *,
                                                        gpointer);
static gboolean        cmacs_video__stall_tick         (gpointer);
static gboolean        cmacs_video__reconnect_idle     (gpointer);
static gboolean        cmacs_video__redraw_idle        (gpointer);
static gboolean        cmacs_video__deliver_state_idle (gpointer);

static void            cmacs_video__set_state          (CmacsVideoStream *,
                                                        CmacsVideoState,
                                                        Lisp_Object detail);
static void            cmacs_video__realloc_buffers    (CmacsVideoStream *,
                                                        int w, int h);
static void            cmacs_video__schedule_reconnect (CmacsVideoStream *);
static gboolean        cmacs_video__is_live_uri        (const char *uri);
static guint           cmacs_video__backoff_ms         (guint attempt);

/* ====================================================================
 * Symbols (state names, plist keys)
 * ==================================================================== */

static Lisp_Object Qcv_initializing, Qcv_buffering, Qcv_playing, Qcv_paused;
static Lisp_Object Qcv_stalled, Qcv_reconnecting, Qcv_eos, Qcv_error, Qcv_closed;
static Lisp_Object QCpercent, QCattempt, QCmessage, QCdomain, QCcode;

static gboolean    symbols_inited = FALSE;
static void
cmacs_video__init_symbols (void)
{
  if (symbols_inited)
    return;
  QCcv_callbacks     = intern_c_string (":cmacs-video-callbacks");
  QCcv_anchor_buffer = intern_c_string (":cmacs-video-anchor-buffer");
  QCcv_anchor_marker = intern_c_string (":cmacs-video-anchor-marker");
  QCcv_anchor_frame  = intern_c_string (":cmacs-video-anchor-frame");
  staticpro (&QCcv_callbacks);
  staticpro (&QCcv_anchor_buffer);
  staticpro (&QCcv_anchor_marker);
  staticpro (&QCcv_anchor_frame);
  Qcv_initializing  = intern_c_string ("initializing");
  Qcv_buffering     = intern_c_string ("buffering");
  Qcv_playing       = intern_c_string ("playing");
  Qcv_paused        = intern_c_string ("paused");
  Qcv_stalled       = intern_c_string ("stalled");
  Qcv_reconnecting  = intern_c_string ("reconnecting");
  Qcv_eos           = intern_c_string ("eos");
  Qcv_error         = intern_c_string ("error");
  Qcv_closed        = intern_c_string ("closed");
  QCpercent         = intern_c_string (":percent");
  QCattempt         = intern_c_string (":attempt");
  QCmessage         = intern_c_string (":message");
  QCdomain          = intern_c_string (":domain");
  QCcode            = intern_c_string (":code");
  staticpro (&Qcv_initializing);
  staticpro (&Qcv_buffering);
  staticpro (&Qcv_playing);
  staticpro (&Qcv_paused);
  staticpro (&Qcv_stalled);
  staticpro (&Qcv_reconnecting);
  staticpro (&Qcv_eos);
  staticpro (&Qcv_error);
  staticpro (&Qcv_closed);
  staticpro (&QCpercent);
  staticpro (&QCattempt);
  staticpro (&QCmessage);
  staticpro (&QCdomain);
  staticpro (&QCcode);
  symbols_inited = TRUE;
}

Lisp_Object
cmacs_video_stream_anchor_buffer (CmacsVideoStream *s)
{
  return s ? cmacs_video__lisp_get (s->handle, QCcv_anchor_buffer) : Qnil;
}

Lisp_Object
cmacs_video_stream_anchor_marker (CmacsVideoStream *s)
{
  return s ? cmacs_video__lisp_get (s->handle, QCcv_anchor_marker) : Qnil;
}

Lisp_Object
cmacs_video_state_symbol (CmacsVideoState st)
{
  cmacs_video__init_symbols ();
  switch (st)
    {
    case CMACS_VIDEO_STATE_INITIALIZING: return Qcv_initializing;
    case CMACS_VIDEO_STATE_BUFFERING:    return Qcv_buffering;
    case CMACS_VIDEO_STATE_PLAYING:      return Qcv_playing;
    case CMACS_VIDEO_STATE_PAUSED:       return Qcv_paused;
    case CMACS_VIDEO_STATE_STALLED:      return Qcv_stalled;
    case CMACS_VIDEO_STATE_RECONNECTING: return Qcv_reconnecting;
    case CMACS_VIDEO_STATE_EOS:          return Qcv_eos;
    case CMACS_VIDEO_STATE_ERROR:        return Qcv_error;
    case CMACS_VIDEO_STATE_CLOSED:       return Qcv_closed;
    }
  return Qnil;
}

/* ====================================================================
 * Live-URI detection
 * ==================================================================== */

static gboolean
cmacs_video__is_live_uri (const char *uri)
{
  if (!uri)
    return FALSE;
  return g_str_has_prefix (uri, "rtsp://")
      || g_str_has_prefix (uri, "rtsps://")
      || g_str_has_prefix (uri, "srt://")
      || g_str_has_prefix (uri, "udp://")
      || g_str_has_prefix (uri, "rtp://")
      || g_str_has_prefix (uri, "rtmp://")
      || g_str_has_prefix (uri, "rtmps://");
}

/* ====================================================================
 * Pipeline construction
 * ==================================================================== */

/* Build the video-sink bin: videoconvert ! videoscale ! caps ! appsink. */
static GstElement *
cmacs_video__build_video_sink (CmacsVideoStream *s, GError **error)
{
  GstElement *bin       = gst_bin_new ("cmacs-video-sink");
  GstElement *convert   = gst_element_factory_make ("videoconvert", NULL);
  GstElement *scale     = gst_element_factory_make ("videoscale",   NULL);
  GstElement *capsf     = gst_element_factory_make ("capsfilter",   NULL);
  GstElement *appsink   = gst_element_factory_make ("appsink",      "cmacs-appsink");

  if (!bin || !convert || !scale || !capsf || !appsink)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
                   "missing GStreamer plugin: videoconvert/videoscale/appsink");
      if (bin)     gst_object_unref (bin);
      if (convert) gst_object_unref (convert);
      if (scale)   gst_object_unref (scale);
      if (capsf)   gst_object_unref (capsf);
      if (appsink) gst_object_unref (appsink);
      return NULL;
    }

  GstCaps *caps = gst_caps_new_simple ("video/x-raw",
                                       "format", G_TYPE_STRING, "BGRA",
                                       NULL);
  g_object_set (capsf, "caps", caps, NULL);
  gst_caps_unref (caps);

  g_object_set (appsink,
                "emit-signals",       TRUE,
                "max-buffers",        (guint)2,
                "drop",               TRUE,
                "sync",               (gboolean)!s->is_live,
                NULL);
  g_signal_connect (appsink, "new-sample",
                    G_CALLBACK (cmacs_video__on_new_sample), s);

  gst_bin_add_many (GST_BIN (bin), convert, scale, capsf, appsink, NULL);
  if (!gst_element_link_many (convert, scale, capsf, appsink, NULL))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_NEGOTIATION,
                   "cmacs-video: failed to link video-sink bin");
      gst_object_unref (bin);
      return NULL;
    }

  GstPad *sinkpad = gst_element_get_static_pad (convert, "sink");
  GstPad *ghost   = gst_ghost_pad_new ("sink", sinkpad);
  gst_pad_set_active (ghost, TRUE);
  gst_element_add_pad (bin, ghost);
  gst_object_unref (sinkpad);

  s->appsink = appsink;
  return bin;
}

static GstElement *
cmacs_video__build_audio_sink (CmacsVideoStream *s)
{
  if (s->audio_enabled)
    {
      GstElement *autoout = gst_element_factory_make ("autoaudiosink", NULL);
      return autoout;
    }
  GstElement *fake = gst_element_factory_make ("fakesink", NULL);
  if (fake)
    g_object_set (fake, "sync", FALSE, NULL);
  return fake;
}

static gboolean
cmacs_video__attach_bus_watch (CmacsVideoStream *s)
{
  s->bus = gst_pipeline_get_bus (GST_PIPELINE (s->pipeline));
  if (!s->bus)
    return FALSE;
  s->bus_watch = gst_bus_create_watch (s->bus);
  if (!s->bus_watch)
    return FALSE;
  g_source_set_callback (s->bus_watch,
                         G_SOURCE_FUNC (cmacs_video__on_bus_message),
                         /* G_SOURCE_FUNC, not a plain cast: a bus watch
                            callback really is a GstBusFunc, and casting it
                            straight to GSourceFunc is a cast between
                            incompatible function types.  The macro routes
                            it through void(*)(void), which is the form
                            GLib defines for exactly this. */
                         s, NULL);
  g_source_attach (s->bus_watch, cmacs_glib_get_context ());
  /* Context now holds a ref; drop ours. */
  g_source_unref (s->bus_watch);
  return TRUE;
}

static void
cmacs_video__attach_stall_watchdog (CmacsVideoStream *s)
{
  s->stall_timer = g_timeout_source_new_seconds (1);
  g_source_set_callback (s->stall_timer,
                         cmacs_video__stall_tick, s, NULL);
  g_source_attach (s->stall_timer, cmacs_glib_get_context ());
  g_source_unref (s->stall_timer);
}

static CmacsVideoStream *
cmacs_video__new_common (int target_w, int target_h)
{
  cmacs_video__init_symbols ();

  CmacsVideoStream *s = g_new0 (CmacsVideoStream, 1);
  s->target_w           = target_w  > 0 ? target_w  : 640;
  s->target_h           = target_h  > 0 ? target_h  : 360;
  s->volume             = 1.0;
  s->latency_ms         = 200;
  s->state              = CMACS_VIDEO_STATE_INITIALIZING;
  s->stall_threshold_us = 5 * G_USEC_PER_SEC;
  s->stall_grace_us     = 3 * G_USEC_PER_SEC;
  s->last_sample_us     = g_get_monotonic_time ();
  g_mutex_init (&s->frame_mtx);
  g_mutex_init (&s->cb_mtx);
  /* Lisp state (callbacks, anchor) lives in the global hash to keep
   * GC roots stable across stream destroy.  Populated lazily via
   * cmacs_video__lisp_set keyed on s->handle (assigned by registry). */
  cmacs_video__lisp_state_ensure ();
  return s;
}

CmacsVideoStream *
cmacs_video_stream_new (const char *uri, int target_w, int target_h,
                        GError **error)
{
  if (!uri || !*uri)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-video: URI is empty");
      return NULL;
    }

  CmacsVideoStream *s = cmacs_video__new_common (target_w, target_h);
  s->uri     = g_strdup (uri);
  s->is_live = cmacs_video__is_live_uri (uri);

  s->pipeline = gst_element_factory_make ("playbin3", NULL);
  if (!s->pipeline)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
                   "cmacs-video: playbin3 element not available");
      cmacs_video_stream_destroy (s);
      return NULL;
    }
  g_object_set (s->pipeline, "uri", s->uri, NULL);

  GstElement *vsink = cmacs_video__build_video_sink (s, error);
  if (!vsink)
    {
      cmacs_video_stream_destroy (s);
      return NULL;
    }
  g_object_set (s->pipeline, "video-sink", vsink, NULL);

  GstElement *asink = cmacs_video__build_audio_sink (s);
  if (asink)
    g_object_set (s->pipeline, "audio-sink", asink, NULL);

  /* Hook source-setup so we can poke rtspsrc properties once the
   * source element materialises. */
  g_signal_connect (s->pipeline, "source-setup",
                    G_CALLBACK (cmacs_video__on_source_setup), s);

  if (!cmacs_video__attach_bus_watch (s))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-video: failed to attach bus watch");
      cmacs_video_stream_destroy (s);
      return NULL;
    }

  if (s->is_live)
    cmacs_video__attach_stall_watchdog (s);

  return s;
}

CmacsVideoStream *
cmacs_video_stream_new_test (int target_w, int target_h, GError **error)
{
  CmacsVideoStream *s = cmacs_video__new_common (target_w, target_h);
  s->uri     = g_strdup ("test://videotestsrc");
  s->is_live = FALSE;

  GstElement *pipeline = gst_pipeline_new ("cmacs-video-test");
  GstElement *src      = gst_element_factory_make ("videotestsrc", NULL);
  GstElement *convert  = gst_element_factory_make ("videoconvert", NULL);
  GstElement *scale    = gst_element_factory_make ("videoscale",   NULL);
  GstElement *capsf    = gst_element_factory_make ("capsfilter",   NULL);
  GstElement *appsink  = gst_element_factory_make ("appsink",      "cmacs-appsink");

  if (!pipeline || !src || !convert || !scale || !capsf || !appsink)
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
                   "cmacs-video: missing GStreamer plugin (test)");
      if (pipeline) gst_object_unref (pipeline);
      cmacs_video_stream_destroy (s);
      return NULL;
    }

  g_object_set (src, "is-live", FALSE, "num-buffers", 300, NULL);

  GstCaps *caps = gst_caps_new_simple ("video/x-raw",
                                       "format", G_TYPE_STRING, "BGRA",
                                       "width",  G_TYPE_INT, s->target_w,
                                       "height", G_TYPE_INT, s->target_h,
                                       NULL);
  g_object_set (capsf, "caps", caps, NULL);
  gst_caps_unref (caps);

  g_object_set (appsink,
                "emit-signals", TRUE,
                "max-buffers",  (guint)2,
                "drop",         TRUE,
                "sync",         FALSE,
                NULL);
  g_signal_connect (appsink, "new-sample",
                    G_CALLBACK (cmacs_video__on_new_sample), s);

  gst_bin_add_many (GST_BIN (pipeline), src, convert, scale, capsf, appsink, NULL);
  if (!gst_element_link_many (src, convert, scale, capsf, appsink, NULL))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_NEGOTIATION,
                   "cmacs-video: failed to link test pipeline");
      gst_object_unref (pipeline);
      cmacs_video_stream_destroy (s);
      return NULL;
    }

  s->pipeline = pipeline;
  s->appsink  = appsink;

  if (!cmacs_video__attach_bus_watch (s))
    {
      g_set_error (error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
                   "cmacs-video: failed to attach bus watch (test)");
      cmacs_video_stream_destroy (s);
      return NULL;
    }
  return s;
}

/* ====================================================================
 * Destruction (load-bearing order)
 * ==================================================================== */

void
cmacs_video_stream_destroy (CmacsVideoStream *s)
{
  if (!s)
    return;
  /* 1. Mark closed so the paint hook drops us on any concurrent walk. */
  s->state = CMACS_VIDEO_STATE_CLOSED;

  /* 2. Tear down GSources first so no callbacks fire mid-teardown. */
  if (s->bus_watch)
    {
      g_source_destroy (s->bus_watch);
      s->bus_watch = NULL;
    }
  if (s->stall_timer)
    {
      g_source_destroy (s->stall_timer);
      s->stall_timer = NULL;
    }
  if (s->reconnect_timer_id)
    {
      GSource *src = g_main_context_find_source_by_id (
        cmacs_glib_get_context (), s->reconnect_timer_id);
      if (src) g_source_destroy (src);
      s->reconnect_timer_id = 0;
    }

  /* 3. Stop GStreamer; this BLOCKS until streaming threads unwind.
   *    Required before freeing surface backing storage. */
  if (s->pipeline)
    {
      gst_element_set_state (s->pipeline, GST_STATE_NULL);
      /* Pop any pending bus messages to drain refs. */
      if (s->bus)
        {
          GstMessage *msg;
          while ((msg = gst_bus_pop (s->bus)))
            gst_message_unref (msg);
        }
    }

  /* 4. Destroy cairo surfaces BEFORE freeing backing data. */
  if (s->front) { cairo_surface_destroy (s->front); s->front = NULL; }
  if (s->back)  { cairo_surface_destroy (s->back);  s->back  = NULL; }

  /* 5. Free backing pixel buffers. */
  g_free (s->front_data); s->front_data = NULL;
  g_free (s->back_data);  s->back_data  = NULL;

  /* 6. Drop GStreamer + GLib refs. */
  if (s->bus)        { gst_object_unref (s->bus);        s->bus      = NULL; }
  if (s->pipeline)   { gst_object_unref (s->pipeline);   s->pipeline = NULL; }
  g_clear_object (&s->tls_database);

  /* 7. Free strings + state-callback list. */
  g_free (s->uri); s->uri = NULL;
  if (s->error_log)
    {
      g_array_free (s->error_log, TRUE);
      s->error_log = NULL;
    }

  g_mutex_clear (&s->frame_mtx);
  g_mutex_clear (&s->cb_mtx);
  /* Drop Lisp-side bookkeeping (callbacks, anchor) for this handle.
   * Done last so callers in g_idle dispatch still see a valid plist
   * during teardown.  */
  cmacs_video__lisp_remove (s->handle);
  g_free (s);
}

/* ====================================================================
 * State control
 * ==================================================================== */

void  cmacs_video_stream_play  (CmacsVideoStream *s) {
  if (s && s->pipeline) gst_element_set_state (s->pipeline, GST_STATE_PLAYING);
}
void  cmacs_video_stream_pause (CmacsVideoStream *s) {
  if (s && s->pipeline) gst_element_set_state (s->pipeline, GST_STATE_PAUSED);
}
void  cmacs_video_stream_stop  (CmacsVideoStream *s) {
  if (s && s->pipeline) gst_element_set_state (s->pipeline, GST_STATE_READY);
}

void
cmacs_video_stream_seek_ns (CmacsVideoStream *s, gint64 pos_ns)
{
  if (!s || !s->pipeline) return;
  gst_element_seek_simple (s->pipeline, GST_FORMAT_TIME,
                           GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
                           pos_ns);
}

void
cmacs_video_stream_step (CmacsVideoStream *s, int frames)
{
  if (!s || !s->pipeline) return;
  if (frames >= 0)
    {
      GstEvent *ev = gst_event_new_step (GST_FORMAT_BUFFERS, frames,
                                         1.0, TRUE, FALSE);
      gst_element_send_event (s->pipeline, ev);
    }
  else
    {
      /* Backwards step via seek (single-frame backward unsupported by
       * step event on most demuxers). */
      gint64 pos = cmacs_video_stream_position_ns (s);
      gst_element_seek_simple (s->pipeline, GST_FORMAT_TIME,
                               GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
                               MAX (0, pos - 40 * GST_MSECOND * (-frames)));
    }
}

gint64
cmacs_video_stream_position_ns (CmacsVideoStream *s)
{
  if (!s || !s->pipeline) return -1;
  gint64 pos = -1;
  gst_element_query_position (s->pipeline, GST_FORMAT_TIME, &pos);
  return pos;
}

gint64
cmacs_video_stream_duration_ns (CmacsVideoStream *s)
{
  if (!s || !s->pipeline) return -1;
  gint64 dur = -1;
  gst_element_query_duration (s->pipeline, GST_FORMAT_TIME, &dur);
  return dur;
}

void
cmacs_video_stream_set_volume (CmacsVideoStream *s, double v)
{
  if (!s) return;
  s->volume = CLAMP (v, 0.0, 1.0);
  if (s->pipeline)
    g_object_set (s->pipeline, "volume", s->volume, NULL);
}

void
cmacs_video_stream_set_mute (CmacsVideoStream *s, gboolean mute)
{
  if (!s) return;
  s->muted = mute;
  if (s->pipeline)
    g_object_set (s->pipeline, "mute", mute, NULL);
}

/* ====================================================================
 * Snapshot
 * ==================================================================== */

cairo_surface_t *
cmacs_video_stream_snapshot (CmacsVideoStream *s)
{
  if (!s) return NULL;
  cairo_surface_t *snap = NULL;
  g_mutex_lock (&s->frame_mtx);
  if (s->front && s->frame_w > 0 && s->frame_h > 0)
    {
      snap = cairo_image_surface_create (CAIRO_FORMAT_ARGB32,
                                         s->frame_w, s->frame_h);
      cairo_t *cr = cairo_create (snap);
      cairo_set_source_surface (cr, s->front, 0, 0);
      cairo_paint (cr);
      cairo_destroy (cr);
    }
  g_mutex_unlock (&s->frame_mtx);
  return snap;
}

/* ====================================================================
 * Anchoring
 * ==================================================================== */

void
cmacs_video_stream_attach_buffer (CmacsVideoStream *s, Lisp_Object marker)
{
  if (!s) return;
  cmacs_video__lisp_set (s->handle, QCcv_anchor_marker, marker);
  Lisp_Object buf = (MARKERP (marker) && BUFFERP (Fmarker_buffer (marker)))
                    ? Fmarker_buffer (marker) : Qnil;
  cmacs_video__lisp_set (s->handle, QCcv_anchor_buffer, buf);
  cmacs_video__lisp_set (s->handle, QCcv_anchor_frame, Qnil);
  s->standalone_frame = NULL;
}

void
cmacs_video_stream_attach_frame (CmacsVideoStream *s, struct frame *f,
                                 int x, int y, int w, int h)
{
  if (!s) return;
  cmacs_video__lisp_set (s->handle, QCcv_anchor_buffer, Qnil);
  cmacs_video__lisp_set (s->handle, QCcv_anchor_marker, Qnil);
  /* Keep the frame as a Lisp_Object in the GC-rooted table as well as a
   * raw pointer.  The raw pointer is fine for the paint hook, which runs
   * from the frame's own draw path and therefore only ever sees a live
   * frame -- but the redraw idle below fires asynchronously and can
   * outlive `delete-frame'.  Dereferencing a freed frame there produced
   * a Lisp_Object pointing at reused heap, and the crash surfaced deep
   * inside redisplay with no hint of where it came from.  Same reasoning
   * as the table's own header comment. */
  {
    Lisp_Object fobj;
    XSETFRAME (fobj, f);
    cmacs_video__lisp_set (s->handle, QCcv_anchor_frame, fobj);
  }
  s->standalone_frame = f;
  s->standalone_x = x;
  s->standalone_y = y;
  s->standalone_w = w;
  s->standalone_h = h;
}

void
cmacs_video_stream_detach (CmacsVideoStream *s)
{
  if (!s) return;
  cmacs_video__lisp_set (s->handle, QCcv_anchor_buffer, Qnil);
  cmacs_video__lisp_set (s->handle, QCcv_anchor_marker, Qnil);
  cmacs_video__lisp_set (s->handle, QCcv_anchor_frame, Qnil);
  s->standalone_frame = NULL;
}

/* ====================================================================
 * Observers
 * ==================================================================== */

void
cmacs_video_stream_add_state_handler (CmacsVideoStream *s, Lisp_Object fn)
{
  if (!s || NILP (fn)) return;
  g_mutex_lock (&s->cb_mtx);
  Lisp_Object curr = cmacs_video__lisp_get (s->handle, QCcv_callbacks);
  cmacs_video__lisp_set (s->handle, QCcv_callbacks, Fcons (fn, curr));
  g_mutex_unlock (&s->cb_mtx);
}

void
cmacs_video_stream_remove_state_handler (CmacsVideoStream *s, Lisp_Object fn)
{
  if (!s) return;
  g_mutex_lock (&s->cb_mtx);
  Lisp_Object curr = cmacs_video__lisp_get (s->handle, QCcv_callbacks);
  cmacs_video__lisp_set (s->handle, QCcv_callbacks, Fdelete (fn, curr));
  g_mutex_unlock (&s->cb_mtx);
}

/* ====================================================================
 * State delivery (always on main thread via idle)
 * ==================================================================== */

struct CmacsVideoStateEvent {
  CmacsVideoStream *stream;
  CmacsVideoState   state;
  Lisp_Object       detail;
};

static gboolean
cmacs_video__deliver_state_idle (gpointer ud)
{
  struct CmacsVideoStateEvent *ev = ud;
  if (!ev || !ev->stream)
    goto out;
  CmacsVideoStream *s = ev->stream;
  Lisp_Object handle  = make_int (s->handle);
  Lisp_Object state   = cmacs_video_state_symbol (ev->state);

  g_mutex_lock (&s->cb_mtx);
  Lisp_Object callbacks = cmacs_video__lisp_get (s->handle, QCcv_callbacks);
  g_mutex_unlock (&s->cb_mtx);

  Lisp_Object tail;
  for (tail = callbacks; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object fn = XCAR (tail);
      if (!NILP (fn))
        cmacs_dispatch_safe_call3 (fn, handle, state, ev->detail);
    }
out:
  if (ev)
    {
      /* detail is staticpro'd via cons cells; safe_calln will not free.
       * No additional cleanup needed for Lisp_Object. */
      g_free (ev);
    }
  return G_SOURCE_REMOVE;
}

static void
cmacs_video__set_state (CmacsVideoStream *s, CmacsVideoState st,
                        Lisp_Object detail)
{
  if (!s || s->state == st)
    return;
  s->state = st;

  struct CmacsVideoStateEvent *ev = g_new0 (struct CmacsVideoStateEvent, 1);
  ev->stream = s;
  ev->state  = st;
  ev->detail = NILP (detail) ? Qnil : detail;
  g_main_context_invoke (cmacs_glib_get_context (),
                         cmacs_video__deliver_state_idle, ev);
}

/* ====================================================================
 * Frame double-buffer realloc (called under frame_mtx)
 * ==================================================================== */

static void
cmacs_video__realloc_buffers (CmacsVideoStream *s, int w, int h)
{
  if (s->frame_w == w && s->frame_h == h && s->front && s->back)
    return;
  /* Destroy old surfaces first, then free data. */
  if (s->front) { cairo_surface_destroy (s->front); s->front = NULL; }
  if (s->back)  { cairo_surface_destroy (s->back);  s->back  = NULL; }
  g_free (s->front_data);
  g_free (s->back_data);

  gsize sz = (gsize)w * h * 4;
  s->frame_w = w;
  s->frame_h = h;
  s->front_data = g_malloc0 (sz);
  s->back_data  = g_malloc0 (sz);
  s->front = cairo_image_surface_create_for_data (s->front_data,
              CAIRO_FORMAT_ARGB32, w, h, w * 4);
  s->back  = cairo_image_surface_create_for_data (s->back_data,
              CAIRO_FORMAT_ARGB32, w, h, w * 4);
}

/* ====================================================================
 * Streaming-thread frame callback
 * ==================================================================== */

static gboolean
cmacs_video__redraw_idle (gpointer ud)
{
  CmacsVideoStream *s = ud;
  if (!s || s->state == CMACS_VIDEO_STATE_CLOSED)
    return G_SOURCE_REMOVE;
  g_atomic_int_set (&s->redraw_pending, 0);

  /* For buffer anchors, force window update on the marker's window;
   * for standalone, force the frame.  Cheapest portable mechanism:
   * call out via Lisp force-window-update on the buffer, which marks
   * windows dirty and triggers a redisplay -- pgtk_handle_draw fires
   * and our paint hook runs. */
  Lisp_Object anchor_buf =
    cmacs_video__lisp_get (s->handle, QCcv_anchor_buffer);
  if (BUFFERP (anchor_buf))
    {
      cmacs_dispatch_safe_call1 (intern ("force-window-update"), anchor_buf);
    }
  else
    {
      /* Read the frame from the GC-rooted table rather than
       * XSETFRAME-ing the raw pointer: this callback is queued from the
       * streaming thread and can be dispatched after the frame has been
       * deleted, at which point the raw pointer names freed heap.  A
       * frame object that is merely dead is still valid memory, so
       * FRAME_LIVE_P is answerable; a dangling pointer is not. */
      Lisp_Object frame = cmacs_video__lisp_get (s->handle, QCcv_anchor_frame);
      if (FRAMEP (frame) && FRAME_LIVE_P (XFRAME (frame)))
        cmacs_dispatch_safe_call1 (intern ("force-window-update"), frame);
    }
  return G_SOURCE_REMOVE;
}

static GstFlowReturn
cmacs_video__on_new_sample (GstAppSink *sink, gpointer ud)
{
  CmacsVideoStream *s = ud;
  if (!s || s->state == CMACS_VIDEO_STATE_CLOSED)
    return GST_FLOW_FLUSHING;

  GstSample *sample = gst_app_sink_pull_sample (sink);
  if (!sample)
    return GST_FLOW_ERROR;

  GstBuffer *buf  = gst_sample_get_buffer (sample);
  GstCaps   *caps = gst_sample_get_caps (sample);
  if (!buf || !caps)
    {
      gst_sample_unref (sample);
      return GST_FLOW_OK;
    }

  GstVideoInfo vinfo;
  if (!gst_video_info_from_caps (&vinfo, caps))
    {
      gst_sample_unref (sample);
      return GST_FLOW_OK;
    }
  int w = GST_VIDEO_INFO_WIDTH  (&vinfo);
  int h = GST_VIDEO_INFO_HEIGHT (&vinfo);

  GstMapInfo info;
  if (!gst_buffer_map (buf, &info, GST_MAP_READ))
    {
      gst_sample_unref (sample);
      return GST_FLOW_ERROR;
    }

  g_mutex_lock (&s->frame_mtx);
  if (s->frame_w != w || s->frame_h != h)
    cmacs_video__realloc_buffers (s, w, h);
  if (s->back_data)
    {
      gsize cap = (gsize)w * h * 4;
      memcpy (s->back_data, info.data, MIN (info.size, cap));
      cairo_surface_mark_dirty (s->back);

      /* Swap back<->front. */
      cairo_surface_t *tmp_s = s->front; s->front = s->back; s->back = tmp_s;
      guint8 *tmp_d         = s->front_data;
      s->front_data         = s->back_data;
      s->back_data          = tmp_d;
    }
  s->last_sample_us = g_get_monotonic_time ();
  s->frames_decoded++;
  g_mutex_unlock (&s->frame_mtx);

  gst_buffer_unmap (buf, &info);
  gst_sample_unref (sample);

  /* Coalesce redraw idles. */
  if (g_atomic_int_compare_and_exchange (&s->redraw_pending, 0, 1))
    g_main_context_invoke (cmacs_glib_get_context (),
                           cmacs_video__redraw_idle, s);

  return GST_FLOW_OK;
}

/* ====================================================================
 * source-setup: poke rtspsrc properties
 * ==================================================================== */

static void
cmacs_video__on_source_setup (GstElement *playbin, GstElement *src, gpointer ud)
{
  (void) playbin;
  CmacsVideoStream *s = ud;
  if (!s || !src)
    return;
  const char *factory_name = G_OBJECT_TYPE_NAME (src);
  if (!factory_name || (strstr (factory_name, "GstRTSPSrc") == NULL
                        && strstr (factory_name, "RTSPSrc")  == NULL))
    return;

  guint tls_flags;
  if (s->insecure_tls)
    tls_flags = 0;
  else if (s->tls_database)
    {
      g_object_set (src, "tls-database", s->tls_database, NULL);
      tls_flags = 0;
    }
  else
    {
      /* Lenient on identity, strict on expiry/revoke -- the common
       * NVR self-signed-cert case. */
      tls_flags = G_TLS_CERTIFICATE_UNKNOWN_CA
                | G_TLS_CERTIFICATE_BAD_IDENTITY
                | G_TLS_CERTIFICATE_INSECURE;
    }

  g_object_set (src,
                "tls-validation-flags", tls_flags,
                "latency",              (guint)s->latency_ms,
                "drop-on-latency",      TRUE,
                "do-retransmission",    FALSE,
                /* TCP-only (RFC 2326 lower transport = 0x4).  For IP
                 * cameras over LAN this is the right default: UDP can
                 * deliver out-of-order or partially-decrypted RTP that
                 * downstream rtph264depay / h264parse can't reliably
                 * recover from (h264parse has an upstream NULL-deref
                 * bug in gst_base_parse_handle_buffer when fed
                 * malformed buffers).  TCP avoids the failure mode
                 * entirely.  An :rtsp-protocols keyword to override
                 * is on the deferred list.  */
                "protocols",            (guint)0x4,
                NULL);
  s->rtspsrc = src;
}

/* ====================================================================
 * Bus message dispatch (main thread via cmacs_glib_get_context)
 * ==================================================================== */

static gboolean
cmacs_video__on_bus_message (GstBus *bus, GstMessage *msg, gpointer ud)
{
  (void) bus;
  CmacsVideoStream *s = ud;
  if (!s || s->state == CMACS_VIDEO_STATE_CLOSED)
    return G_SOURCE_REMOVE;

  switch (GST_MESSAGE_TYPE (msg))
    {
    case GST_MESSAGE_STATE_CHANGED:
      /* Only watch pipeline-level state changes. */
      if (GST_MESSAGE_SRC (msg) == GST_OBJECT (s->pipeline))
        {
          GstState old_s, new_s, pending_s;
          gst_message_parse_state_changed (msg, &old_s, &new_s, &pending_s);
          CmacsVideoState mapped = s->state;
          switch (new_s)
            {
            case GST_STATE_NULL:
            case GST_STATE_READY:    mapped = CMACS_VIDEO_STATE_INITIALIZING; break;
            case GST_STATE_PAUSED:   mapped = CMACS_VIDEO_STATE_PAUSED;       break;
            case GST_STATE_PLAYING:  mapped = CMACS_VIDEO_STATE_PLAYING;
              s->reconnect_attempt = 0;
              break;
            default: break;
            }
          if (mapped != s->state)
            cmacs_video__set_state (s, mapped, Qnil);
        }
      break;

    case GST_MESSAGE_BUFFERING:
      {
        gint percent = 100;
        gst_message_parse_buffering (msg, &percent);
        if (percent < 100)
          {
            Lisp_Object detail = list2 (QCpercent, make_fixnum (percent));
            cmacs_video__set_state (s, CMACS_VIDEO_STATE_BUFFERING, detail);
          }
        else if (s->state != CMACS_VIDEO_STATE_PAUSED)
          cmacs_video__set_state (s, CMACS_VIDEO_STATE_PLAYING, Qnil);
        break;
      }

    case GST_MESSAGE_EOS:
      if (s->is_live)
        {
          cmacs_video__schedule_reconnect (s);
        }
      else if (s->loop_p)
        {
          gst_element_seek_simple (s->pipeline, GST_FORMAT_TIME,
                                   GST_SEEK_FLAG_FLUSH, 0);
          gst_element_set_state (s->pipeline, GST_STATE_PLAYING);
        }
      else
        cmacs_video__set_state (s, CMACS_VIDEO_STATE_EOS, Qnil);
      break;

    case GST_MESSAGE_ERROR:
      {
        GError *err = NULL;
        gchar  *dbg = NULL;
        gst_message_parse_error (msg, &err, &dbg);
        Lisp_Object detail =
          list4 (QCmessage, err ? build_string (err->message) : Qnil,
                 QCdomain,  err ? make_fixnum (err->domain)   : Qnil);
        (void)dbg;
        cmacs_video__set_state (s, CMACS_VIDEO_STATE_ERROR, detail);
        if (s->is_live)
          cmacs_video__schedule_reconnect (s);
        if (err) g_error_free (err);
        g_free (dbg);
        break;
      }

    case GST_MESSAGE_WARNING:
      /* Suppress noisy RTP receive warnings. */
      break;

    default:
      break;
    }
  return G_SOURCE_CONTINUE;
}

/* ====================================================================
 * Stall watchdog (1 Hz)
 * ==================================================================== */

static gboolean
cmacs_video__stall_tick (gpointer ud)
{
  CmacsVideoStream *s = ud;
  if (!s || s->state == CMACS_VIDEO_STATE_CLOSED || !s->is_live)
    return G_SOURCE_CONTINUE;
  if (s->state == CMACS_VIDEO_STATE_PAUSED
      || s->state == CMACS_VIDEO_STATE_RECONNECTING
      || s->state == CMACS_VIDEO_STATE_ERROR
      || s->state == CMACS_VIDEO_STATE_EOS
      || s->state == CMACS_VIDEO_STATE_INITIALIZING)
    return G_SOURCE_CONTINUE;

  gint64 now = g_get_monotonic_time ();
  gint64 idle;
  g_mutex_lock (&s->frame_mtx);
  idle = now - s->last_sample_us;
  g_mutex_unlock (&s->frame_mtx);

  if (idle > s->stall_threshold_us + s->stall_grace_us)
    {
      cmacs_video__set_state (s, CMACS_VIDEO_STATE_RECONNECTING, Qnil);
      cmacs_video__schedule_reconnect (s);
    }
  else if (idle > s->stall_threshold_us && s->state != CMACS_VIDEO_STATE_STALLED)
    {
      cmacs_video__set_state (s, CMACS_VIDEO_STATE_STALLED, Qnil);
    }
  return G_SOURCE_CONTINUE;
}

/* ====================================================================
 * Reconnect with exponential backoff
 * ==================================================================== */

static guint
cmacs_video__backoff_ms (guint attempt)
{
  static const guint table[] = {1000, 2000, 4000, 8000, 16000, 32000, 60000};
  return table[MIN (attempt, (guint)(G_N_ELEMENTS (table) - 1))];
}

static gboolean
cmacs_video__reconnect_idle (gpointer ud)
{
  CmacsVideoStream *s = ud;
  if (!s || s->state == CMACS_VIDEO_STATE_CLOSED || !s->pipeline)
    return G_SOURCE_REMOVE;

  s->reconnect_timer_id = 0;
  s->reconnect_attempt++;

  gst_element_set_state (s->pipeline, GST_STATE_NULL);
  /* Drain stale bus errors before going back to PLAYING. */
  if (s->bus)
    {
      GstMessage *m;
      while ((m = gst_bus_pop_filtered (s->bus,
                  GST_MESSAGE_ERROR | GST_MESSAGE_WARNING)))
        gst_message_unref (m);
    }
  gst_element_set_state (s->pipeline, GST_STATE_PLAYING);
  /* Reset the stall clock so we don't immediately retrigger. */
  g_mutex_lock (&s->frame_mtx);
  s->last_sample_us = g_get_monotonic_time ();
  g_mutex_unlock (&s->frame_mtx);
  return G_SOURCE_REMOVE;
}

static void
cmacs_video__schedule_reconnect (CmacsVideoStream *s)
{
  if (!s || s->reconnect_timer_id != 0)
    return;
  guint ms = cmacs_video__backoff_ms (s->reconnect_attempt);
  GSource *src = g_timeout_source_new (ms);
  g_source_set_callback (src, cmacs_video__reconnect_idle, s, NULL);
  s->reconnect_timer_id = g_source_attach (src, cmacs_glib_get_context ());
  g_source_unref (src);
}

#endif /* HAVE_CMACS_VIDEO */
