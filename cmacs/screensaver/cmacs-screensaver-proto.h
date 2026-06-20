/* cmacs-screensaver-proto.h --- shared wire/shm protocol for the screensaver
 * out-of-process renderer.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * This file is PURE C: it depends on glib + json-glib only -- never on lisp.h,
 * libregnum, gowl, GL, or raylib.  It is compiled into BOTH the Emacs binary
 * (the reader/manager side) and the standalone `cmacs-screensaver-render' child
 * (the writer side), so the shared-memory frame layout, the seqlock, and the
 * JSON control vocabulary are defined exactly once and unit-tested in isolation.
 *
 * Frame transport: a per-target POSIX shared-memory region (a sealed memfd)
 * holds a small fixed header followed by SCR_SHM_N_SLOTS pixel slots.  The child
 * is the single writer, Emacs the single reader; a per-slot seqlock plus a
 * `latest' index give lock-free, tear-free, latest-value handoff (old frames are
 * intentionally dropped).  All atomics use the GCC/Clang __atomic builtins on
 * plain integer fields, so ScrShmHeader stays a fixed-layout POD usable across
 * the process boundary.
 *
 * Control transport: one JSON object per SOCK_SEQPACKET datagram (the datagram
 * boundary frames the message; the frame-buffer announce additionally carries a
 * single memfd via SCM_RIGHTS).  */

#ifndef CMACS_SCREENSAVER_PROTO_H
#define CMACS_SCREENSAVER_PROTO_H

#include <glib.h>
#include <stdint.h>

G_BEGIN_DECLS

/* ---- shared-memory frame ring ------------------------------------------- */

#define SCR_SHM_MAGIC     0x53535230u  /* 'S','S','R','0' */
#define SCR_SHM_VERSION   1u
#define SCR_SHM_N_SLOTS   3u            /* triple buffer: writer never blocks */
#define SCR_SHM_SENTINEL  0xFFFFFFFFu   /* `latest' value meaning "no frame" */
#define SCR_SHM_MAX_DIM   16384u        /* per-axis sanity cap */

/* Fixed-layout header at offset 0 of every frame memfd.  Identical in both
 * compilations (asserted below); the `latest', `seq[]' and `generation' fields
 * are accessed only through the __atomic builtins in the helpers. */
typedef struct
{
  uint32_t magic;       /* SCR_SHM_MAGIC */
  uint32_t version;     /* SCR_SHM_VERSION */
  uint32_t width;       /* pixels */
  uint32_t height;      /* pixels */
  uint32_t stride;      /* width * 4 (ARGB8888 == GL_BGRA byte order) */
  uint32_t n_slots;     /* SCR_SHM_N_SLOTS */
  uint64_t slot_bytes;  /* (uint64_t) stride * height */
  uint64_t pixels_off;  /* byte offset of slot 0 (== sizeof (ScrShmHeader)) */
  uint64_t generation;  /* atomic: total frames published (0 == none yet) */
  uint32_t latest;      /* atomic: newest published slot index, or SENTINEL */
  uint32_t seq[SCR_SHM_N_SLOTS]; /* atomic: per-slot seqlock, odd == writing */
} ScrShmHeader;

G_STATIC_ASSERT (sizeof (ScrShmHeader) == 64);
G_STATIC_ASSERT (SCR_SHM_N_SLOTS == 3);

/* A coherent frame latched by the reader. */
typedef struct
{
  const void *pixels;     /* slot pixel data, or NULL if no frame available */
  uint32_t    idx;        /* slot index */
  uint32_t    seq;        /* slot seqlock value at acquire (even) */
  uint64_t    generation; /* publish generation of this frame */
} ScrShmFrame;

/* TRUE if W,H are within sane, non-zero bounds. */
gboolean scr_shm_dims_valid (uint32_t w, uint32_t h);

/* Total memfd size for a W*H target (header + N_SLOTS pixel slots), or 0 if the
 * dimensions are invalid or the computation would overflow. */
gsize scr_shm_total_size (uint32_t w, uint32_t h);

/* Initialise the header of a freshly-sized region: magic/version/dims, latest =
 * SENTINEL, all seqs even (0), generation 0.  BASE must be at least
 * scr_shm_total_size (w, h) bytes. */
void scr_shm_header_init (void *base, uint32_t w, uint32_t h);

/* Validate a mapped region: correct magic + version + n_slots, and (when
 * EXPECT_W/EXPECT_H are non-zero) matching dimensions. */
gboolean scr_shm_header_validate (const void *base,
                                  uint32_t expect_w, uint32_t expect_h);

/* Pixel pointer for slot IDX (no bounds checking beyond IDX < n_slots). */
void *scr_shm_slot_ptr (void *base, uint32_t idx);

/* Writer (child) side ----------------------------------------------------- */

/* Choose the next slot to write into: never `latest', never LAST_WRITTEN.  With
 * 3 slots such a slot always exists, so the writer never blocks. */
uint32_t scr_shm_writer_pick (const void *base, uint32_t last_written);

/* Mark slot IDX as being written (seq -> odd) and return its pixel pointer. */
void *scr_shm_write_begin (void *base, uint32_t idx);

/* Publish slot IDX: seq -> even (release), latest = IDX, generation++. */
void scr_shm_write_commit (void *base, uint32_t idx);

/* Abandon an in-progress write of slot IDX (e.g. the render failed): restore the
 * slot's seq to even WITHOUT advancing `latest'/`generation', so the slot keeps
 * whatever it last published and the reader is unaffected. */
void scr_shm_write_abort (void *base, uint32_t idx);

/* Reader (Emacs) side ----------------------------------------------------- */

/* Latch the newest published frame into *OUT.  Returns FALSE (and OUT->pixels
 * NULL) when there is no frame yet or the writer is mid-write -- the caller then
 * simply skips this tick; it never blocks or spins. */
gboolean scr_shm_read_acquire (const void *base, ScrShmFrame *out);

/* After consuming F->pixels, confirm the slot was not overwritten underneath the
 * reader.  TRUE == the frame is still coherent (safe to keep); FALSE == it tore
 * (discard / re-read next tick). */
gboolean scr_shm_read_verify (const void *base, const ScrShmFrame *f);

/* ---- control protocol (one JSON object per SEQPACKET datagram) ----------- */

#define SCR_PROTO_VERSION 1
#define SCR_MSG_MAX_BYTES (64 * 1024)  /* control datagram hard cap */

/* "t" (type) tags. */
#define SCR_MSG_HELLO         "hello"
#define SCR_MSG_HELLO_ACK     "hello-ack"
#define SCR_MSG_SET_TARGET    "set-target"
#define SCR_MSG_REMOVE_TARGET "remove-target"
#define SCR_MSG_SET_FPS       "set-fps"
#define SCR_MSG_PAUSE         "pause"
#define SCR_MSG_PING          "ping"
#define SCR_MSG_PONG          "pong"
#define SCR_MSG_QUIT          "quit"
#define SCR_MSG_FRAME_BUFFER  "frame-buffer"
#define SCR_MSG_LOAD_RESULT   "load-result"
#define SCR_MSG_HEARTBEAT     "heartbeat"
#define SCR_MSG_STOPPED       "stopped"

/* Return a newly-allocated copy of the message's "t" tag (g_free), or NULL if
 * JSON is not a parseable object with a string "t". */
gchar *scr_proto_message_type (const gchar *json, gssize len);

/* set-target (parent -> child). */
typedef struct
{
  int       sink;     /* 0 = wallpaper, 1 = lock */
  gchar    *mon;      /* monitor name (owned) */
  gchar    *so;       /* module .so path (owned) */
  gchar   **args;     /* NULL-terminated argv tail, or NULL (owned) */
  int       w, h;
  gboolean  covered;  /* skip GL render while covered */
} ScrSetTarget;

void     scr_set_target_clear (ScrSetTarget *t);
gchar   *scr_proto_build_set_target (const ScrSetTarget *t);
gboolean scr_proto_parse_set_target (const gchar *json, gssize len,
                                     ScrSetTarget *out);

/* frame-buffer announce (child -> parent, carries 1 fd out of band). */
typedef struct
{
  int    sink;
  gchar *mon;
  int    w, h, stride, slots;
} ScrFrameBuffer;

void     scr_frame_buffer_clear (ScrFrameBuffer *t);
gchar   *scr_proto_build_frame_buffer (const ScrFrameBuffer *t);
gboolean scr_proto_parse_frame_buffer (const gchar *json, gssize len,
                                       ScrFrameBuffer *out);

/* load-result (child -> parent). */
typedef struct
{
  int       sink;
  gchar    *mon;
  gboolean  ok;
  gchar    *err;   /* NULL when ok */
} ScrLoadResult;

void     scr_load_result_clear (ScrLoadResult *t);
gchar   *scr_proto_build_load_result (const ScrLoadResult *t);
gboolean scr_proto_parse_load_result (const gchar *json, gssize len,
                                      ScrLoadResult *out);

/* Simple / scalar messages. */
gchar   *scr_proto_build_simple (const gchar *type);       /* {"t":type} */
gchar   *scr_proto_build_hello (int version);
gchar   *scr_proto_build_set_fps (int fps);
gchar   *scr_proto_build_pause (gboolean paused);
gchar   *scr_proto_build_remove_target (int sink, const gchar *mon);
gchar   *scr_proto_build_heartbeat (gint64 seq);

gboolean scr_proto_parse_hello (const gchar *json, gssize len, int *version_out);
gboolean scr_proto_parse_set_fps (const gchar *json, gssize len, int *fps_out);
gboolean scr_proto_parse_pause (const gchar *json, gssize len,
                                gboolean *paused_out);
gboolean scr_proto_parse_remove_target (const gchar *json, gssize len,
                                        int *sink_out, gchar **mon_out);

G_END_DECLS

#endif /* CMACS_SCREENSAVER_PROTO_H */
