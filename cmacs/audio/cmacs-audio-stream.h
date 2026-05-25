/* cmacs-audio-stream.h --- One GStreamer pipeline per audio stream.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Mirrors cmacs-video-stream.h with PCM rather than BGRA frames and
 * dual capture/playback pipeline modes.
 */

#ifndef CMACS_AUDIO_STREAM_H
#define CMACS_AUDIO_STREAM_H

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "lisp.h"
#include <gst/gst.h>
#include <gio/gio.h>
#include <cairo.h>
#include <stdint.h>

typedef enum {
  CMACS_AUDIO_MODE_CAPTURE = 0,
  CMACS_AUDIO_MODE_PLAYBACK
} CmacsAudioMode;

typedef enum {
  CMACS_AUDIO_STATE_INITIALIZING = 0,
  CMACS_AUDIO_STATE_READY,
  CMACS_AUDIO_STATE_PLAYING,
  CMACS_AUDIO_STATE_PAUSED,
  CMACS_AUDIO_STATE_EOS,
  CMACS_AUDIO_STATE_ERROR,
  CMACS_AUDIO_STATE_CLOSED
} CmacsAudioState;

typedef enum {
  CMACS_AUDIO_SOURCE_AUTO = 0,
  CMACS_AUDIO_SOURCE_PIPEWIRE,
  CMACS_AUDIO_SOURCE_PULSE,
  CMACS_AUDIO_SOURCE_AUDIOTESTSRC,    /* synthetic for tests */
  CMACS_AUDIO_SOURCE_COREAUDIO        /* macOS only */
} CmacsAudioSourceKind;

typedef struct _CmacsAudioStream CmacsAudioStream;

struct _CmacsAudioStream {
  /* --- Identity / public handle --- */
  uint64_t            handle;
  CmacsAudioMode      mode;

  /* For PLAYBACK: source URI ("file://..." or NULL when feeding PCM).
   * For CAPTURE: source kind (pipewire/pulse/auto/test). */
  gchar              *uri;             /* owned, NULL for capture or pcm-fed playback */
  CmacsAudioSourceKind source_kind;
  gchar              *device;          /* optional ALSA/PW device hint, owned */

  /* --- Audio format --- */
  int                 sample_rate;     /* Hz, default 16000 (whisper-ready) */
  int                 channels;        /* default 1 (mono) */
  int                 bit_depth;       /* fixed S16LE = 16 for v1 */

  /* --- GStreamer pipeline --- */
  GstElement         *pipeline;
  GstElement         *appsink;         /* CAPTURE only, weak ref */
  GstElement         *appsrc;          /* PLAYBACK from PCM, weak ref */
  GstElement         *volume_elem;     /* weak ref, PLAYBACK only */
  GstElement         *level_elem;      /* weak ref, optional level meter */
  GstBus             *bus;             /* strong ref */
  GSource            *bus_watch;       /* attached to cmacs_glib_get_context() */

  /* --- PCM double buffer ---
   *
   * Ring buffer of S16LE samples, capacity ~5 s by default.  The
   * streaming-thread appsink callback (CAPTURE) or appsrc need-data
   * handler (PLAYBACK) holds frame_mtx briefly, copies samples into
   * back, swaps back<->front, unlocks.  All Lisp-visible drains read
   * front under frame_mtx. */
  GMutex              frame_mtx;
  int16_t            *front_pcm;       /* owned (g_malloc0) */
  int16_t            *back_pcm;        /* owned */
  guint               capacity_frames; /* per-buffer capacity (in mono frames) */
  guint               front_fill;      /* valid samples in front */
  guint               back_fill;       /* fill cursor for back */
  gint64              last_sample_us;
  gint64              frames_processed;

  /* --- Cached waveform surface (set by cmacs-audio-waveform.c) --- */
  cairo_surface_t    *waveform_surface;
  int                 waveform_w;
  int                 waveform_h;
  gboolean            waveform_dirty;

  /* --- Anchoring (dual: buffer marker via lisp_state hash, or
   *     frame rect in-struct) --- */
  struct frame       *standalone_frame;
  int                 standalone_x;
  int                 standalone_y;
  int                 standalone_w;
  int                 standalone_h;

  /* --- Playback knobs --- */
  double              volume;          /* 0.0..1.0 default 1.0 */
  gboolean            muted;
  gboolean            loop_p;
  gboolean            level_meter_enabled;

  /* --- Lifecycle + observation --- */
  CmacsAudioState     state;
  GMutex              cb_mtx;
  GArray             *error_log;       /* capped GArray */
  /* Level meter latest reading; updated from bus message callback. */
  double              last_peak_db;
  double              last_rms_db;
  gint64              last_level_us;
};

/* --- Lifecycle --- */
extern CmacsAudioStream *cmacs_audio_stream_new_capture (CmacsAudioSourceKind kind,
                                                         const char *device,
                                                         int rate, int channels,
                                                         gboolean enable_level,
                                                         GError **error);
extern CmacsAudioStream *cmacs_audio_stream_new_playback_file (const char *uri,
                                                               GError **error);
extern CmacsAudioStream *cmacs_audio_stream_new_playback_pcm (int rate,
                                                              int channels,
                                                              GError **error);
extern void              cmacs_audio_stream_destroy (CmacsAudioStream *s);

/* --- State control --- */
extern void cmacs_audio_stream_start (CmacsAudioStream *s);
extern void cmacs_audio_stream_pause (CmacsAudioStream *s);
extern void cmacs_audio_stream_stop  (CmacsAudioStream *s);
extern void cmacs_audio_stream_seek_ns (CmacsAudioStream *s, gint64 pos_ns);
extern gint64 cmacs_audio_stream_position_ns (CmacsAudioStream *s);
extern gint64 cmacs_audio_stream_duration_ns (CmacsAudioStream *s);

/* --- Volume --- */
extern void cmacs_audio_stream_set_volume (CmacsAudioStream *s, double v);
extern void cmacs_audio_stream_set_mute   (CmacsAudioStream *s, gboolean m);

/* --- PCM I/O --- */
/* Drain up to `n_frames' from front-buffer into `out' (S16LE bytes).
 * Returns number of frames actually drained.  Resets front_fill. */
extern guint cmacs_audio_stream_drain_pcm (CmacsAudioStream *s,
                                           int16_t *out, guint n_frames);
/* For PLAYBACK-PCM streams: push `n_frames' of PCM samples for output. */
extern gboolean cmacs_audio_stream_push_pcm (CmacsAudioStream *s,
                                             const int16_t *in, guint n_frames);
/* Write a WAV file containing the entire capture history so far. */
extern gboolean cmacs_audio_stream_write_wav (CmacsAudioStream *s,
                                              const char *path, GError **err);

/* --- Anchoring --- */
extern void cmacs_audio_stream_attach_buffer (CmacsAudioStream *s,
                                              Lisp_Object marker);
extern void cmacs_audio_stream_attach_frame  (CmacsAudioStream *s,
                                              struct frame *f,
                                              int x, int y, int w, int h);
extern void cmacs_audio_stream_detach        (CmacsAudioStream *s);

/* --- Observers --- */
extern void cmacs_audio_stream_add_state_handler    (CmacsAudioStream *s,
                                                     Lisp_Object fn);
extern void cmacs_audio_stream_remove_state_handler (CmacsAudioStream *s,
                                                     Lisp_Object fn);
extern void cmacs_audio_stream_add_level_handler    (CmacsAudioStream *s,
                                                     Lisp_Object fn);
extern void cmacs_audio_stream_remove_level_handler (CmacsAudioStream *s,
                                                     Lisp_Object fn);

/* Map state/source enum <-> Lisp symbol. */
extern Lisp_Object cmacs_audio_state_symbol  (CmacsAudioState st);
extern Lisp_Object cmacs_audio_source_symbol (CmacsAudioSourceKind k);
extern CmacsAudioSourceKind cmacs_audio_source_from_symbol (Lisp_Object sym);

/* Lisp-side anchor accessors (stored in cmacs_audio__lisp_state). */
extern Lisp_Object cmacs_audio_stream_anchor_buffer (CmacsAudioStream *s);
extern Lisp_Object cmacs_audio_stream_anchor_marker (CmacsAudioStream *s);

#endif /* HAVE_CMACS_AUDIO */
#endif /* CMACS_AUDIO_STREAM_H */
