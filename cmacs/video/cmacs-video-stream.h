/* cmacs-video-stream.h --- One GStreamer playbin3 pipeline per stream.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_VIDEO_STREAM_H
#define CMACS_VIDEO_STREAM_H

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "lisp.h"
#include <gst/gst.h>
#include <gio/gio.h>
#include <cairo.h>
#include <stdint.h>

typedef enum {
  CMACS_VIDEO_STATE_INITIALIZING = 0,
  CMACS_VIDEO_STATE_BUFFERING,
  CMACS_VIDEO_STATE_PLAYING,
  CMACS_VIDEO_STATE_PAUSED,
  CMACS_VIDEO_STATE_STALLED,
  CMACS_VIDEO_STATE_RECONNECTING,
  CMACS_VIDEO_STATE_EOS,
  CMACS_VIDEO_STATE_ERROR,
  CMACS_VIDEO_STATE_CLOSED         /* terminal */
} CmacsVideoState;

typedef struct _CmacsVideoStream CmacsVideoStream;

struct _CmacsVideoStream {
  /* --- Identity / public handle --- */
  uint64_t          handle;
  gchar            *uri;             /* owned */
  gboolean          is_live;         /* derived from uri prefix */

  /* --- GStreamer pipeline --- */
  GstElement       *pipeline;        /* playbin3 (or synthetic test source) */
  GstElement       *appsink;         /* weak ref into pipeline bin */
  GstElement       *rtspsrc;         /* weak ref, set in source-setup */
  GstBus           *bus;             /* strong ref */
  GSource          *bus_watch;       /* attached to cmacs_glib_get_context() */
  GSource          *stall_timer;     /* 1Hz watchdog */
  guint             reconnect_timer_id;

  /* --- Frame double buffer ---
   *
   * Streaming thread writes into `back', then under `frame_mtx' swaps
   * back<->front.  Paint hook reads `front' under `frame_mtx'.  Backing
   * pixel storage is owned by us (g_malloc0'd); surfaces wrap it via
   * cairo_image_surface_create_for_data and must be destroyed before
   * the backing data is freed.
   */
  GMutex            frame_mtx;
  cairo_surface_t  *front;
  cairo_surface_t  *back;
  guint8           *front_data;
  guint8           *back_data;
  int               frame_w, frame_h;    /* native decoded dimensions */
  int               target_w, target_h;  /* requested display size */
  gint64            last_sample_us;
  gint64            frames_decoded;
  gint              redraw_pending;      /* atomic */

  /* --- Anchoring ---
   *
   * For in-buffer overlay anchoring, the (anchor-buffer, anchor-marker)
   * Lisp pair lives in the global `cmacs_video__lisp_state' hash
   * keyed by handle (so the GC roots stay stable even as streams
   * are created/destroyed).  For standalone-mode anchoring, the
   * frame + rect lives in-struct because struct frame* is not a
   * Lisp_Object.
   */
  struct frame     *standalone_frame;    /* NULL unless standalone */
  int               standalone_x;
  int               standalone_y;
  int               standalone_w;
  int               standalone_h;

  /* --- Audio --- */
  gboolean          audio_enabled;
  double            volume;
  gboolean          muted;

  /* --- RTSP/live knobs --- */
  gboolean          insecure_tls;
  GTlsDatabase     *tls_database;        /* nullable, owned */
  int               latency_ms;
  guint             reconnect_attempt;

  /* --- Lifecycle + observation ---
   * state_callbacks list lives in cmacs_video__lisp_state (see .c).
   * cb_mtx guards concurrent add/remove from the bus thread. */
  CmacsVideoState   state;
  GMutex            cb_mtx;
  /* error_log: GArray of struct CmacsVideoError { ts; domain; code;
   * msg; debug; } -- capped at 32 entries.  Allocated lazily. */
  GArray           *error_log;
  gboolean          loop_p;
  gboolean          autoplay;
  gint64            start_ns;            /* initial seek */
  gint64            stall_threshold_us;  /* default 5_000_000 */
  gint64            stall_grace_us;      /* default 3_000_000 */
};

/* --- Lifecycle --- */
extern CmacsVideoStream *cmacs_video_stream_new (const char *uri,
                                                 int target_w, int target_h,
                                                 GError **error);
extern CmacsVideoStream *cmacs_video_stream_new_test (int target_w,
                                                      int target_h,
                                                      GError **error);
extern void              cmacs_video_stream_destroy (CmacsVideoStream *s);

/* --- State control --- */
extern void  cmacs_video_stream_play   (CmacsVideoStream *s);
extern void  cmacs_video_stream_pause  (CmacsVideoStream *s);
extern void  cmacs_video_stream_stop   (CmacsVideoStream *s);
extern void  cmacs_video_stream_seek_ns(CmacsVideoStream *s, gint64 pos_ns);
extern void  cmacs_video_stream_step   (CmacsVideoStream *s, int frames);
extern gint64 cmacs_video_stream_position_ns (CmacsVideoStream *s);
extern gint64 cmacs_video_stream_duration_ns (CmacsVideoStream *s);

/* --- Audio --- */
extern void  cmacs_video_stream_set_volume (CmacsVideoStream *s, double v);
extern void  cmacs_video_stream_set_mute   (CmacsVideoStream *s, gboolean mute);

/* --- Frame snapshot ---
 * Allocates and returns a fresh ARGB32 cairo surface containing a deep
 * copy of the current front frame.  Returns NULL if no frame yet. */
extern cairo_surface_t *cmacs_video_stream_snapshot (CmacsVideoStream *s);

/* --- Anchoring (called from defuns) --- */
extern void  cmacs_video_stream_attach_buffer (CmacsVideoStream *s,
                                               Lisp_Object marker);
extern void  cmacs_video_stream_attach_frame  (CmacsVideoStream *s,
                                               struct frame *f,
                                               int x, int y, int w, int h);
extern void  cmacs_video_stream_detach        (CmacsVideoStream *s);

/* --- Observers --- */
extern void  cmacs_video_stream_add_state_handler    (CmacsVideoStream *s,
                                                      Lisp_Object fn);
extern void  cmacs_video_stream_remove_state_handler (CmacsVideoStream *s,
                                                      Lisp_Object fn);

/* --- Frame readout (paint hook).  Caller must hold frame_mtx. ---
 * Returns the current front cairo_surface_t (do NOT destroy), or NULL. */
static inline cairo_surface_t *
cmacs_video_stream_peek_front_locked (CmacsVideoStream *s)
{
  return s ? s->front : NULL;
}

/* Map state enum <-> Lisp symbol. */
extern Lisp_Object cmacs_video_state_symbol (CmacsVideoState st);

/* Lisp-side accessors (anchor info lives in a shared hash to keep
 * GC roots stable across stream lifecycle). */
extern Lisp_Object cmacs_video_stream_anchor_buffer (CmacsVideoStream *s);
extern Lisp_Object cmacs_video_stream_anchor_marker (CmacsVideoStream *s);

#endif /* HAVE_CMACS_VIDEO */
#endif /* CMACS_VIDEO_STREAM_H */
