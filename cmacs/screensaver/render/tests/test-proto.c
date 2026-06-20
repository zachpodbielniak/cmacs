/* test-proto.c --- unit tests for the screensaver shared protocol + seqlock.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pure tests: no Emacs, no GL, no real render child.  Exercises the lock-free
 * shared-memory frame ring (including a multi-threaded tear-detection stress),
 * the shm layout/validation math, the JSON control vocabulary, real SCM_RIGHTS
 * fd passing over a SEQPACKET socketpair, and memfd size sealing. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "cmacs-screensaver-proto.h"

#include <gio/gio.h>
#include <gio/gunixfdmessage.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

/* ---- shm layout ---------------------------------------------------------- */

static void
test_layout (void)
{
  /* Header is a fixed 64-byte POD; pixels begin right after it. */
  g_assert_cmpuint (sizeof (ScrShmHeader), ==, 64);
  g_assert_cmpuint (SCR_SHM_N_SLOTS, ==, 3);

  g_assert_true (scr_shm_dims_valid (1, 1));
  g_assert_true (scr_shm_dims_valid (2560, 1440));
  g_assert_false (scr_shm_dims_valid (0, 100));
  g_assert_false (scr_shm_dims_valid (100, 0));
  g_assert_false (scr_shm_dims_valid (SCR_SHM_MAX_DIM + 1, 100));
}

static void
test_total_size (void)
{
  gsize sz = scr_shm_total_size (64, 48);
  g_assert_cmpuint (sz, ==, 64 + (gsize) 3 * 64 * 4 * 48);

  g_assert_cmpuint (scr_shm_total_size (0, 48), ==, 0);
  g_assert_cmpuint (scr_shm_total_size (48, 0), ==, 0);
  /* Above the per-axis cap -> rejected (no overflow). */
  g_assert_cmpuint (scr_shm_total_size (SCR_SHM_MAX_DIM + 1, 1), ==, 0);
  /* Max dims (16384x16384 -> ~3 GiB, under the 4 GiB ceiling) are accepted and
   * computed without overflow. */
  g_assert_cmpuint (scr_shm_total_size (SCR_SHM_MAX_DIM, SCR_SHM_MAX_DIM), ==,
                    64 + (gsize) 3 * SCR_SHM_MAX_DIM * 4 * SCR_SHM_MAX_DIM);
}

static void
test_header_init_validate (void)
{
  gsize sz = scr_shm_total_size (320, 200);
  void *base = g_malloc0 (sz);

  scr_shm_header_init (base, 320, 200);
  g_assert_true (scr_shm_header_validate (base, 320, 200));
  g_assert_true (scr_shm_header_validate (base, 0, 0));       /* dims optional */
  g_assert_false (scr_shm_header_validate (base, 321, 200));  /* wrong w */
  g_assert_false (scr_shm_header_validate (base, 320, 201));  /* wrong h */

  /* Corrupt magic / version -> invalid. */
  ((ScrShmHeader *) base)->magic = 0xdeadbeef;
  g_assert_false (scr_shm_header_validate (base, 320, 200));
  ((ScrShmHeader *) base)->magic = SCR_SHM_MAGIC;
  ((ScrShmHeader *) base)->version = 999;
  g_assert_false (scr_shm_header_validate (base, 320, 200));

  g_free (base);
}

static void
test_read_acquire_empty (void)
{
  gsize sz = scr_shm_total_size (16, 16);
  void *base = g_malloc0 (sz);
  ScrShmFrame f;

  scr_shm_header_init (base, 16, 16);
  /* No frame published yet -> read_acquire fails (latest == SENTINEL). */
  g_assert_false (scr_shm_read_acquire (base, &f));
  g_assert_null (f.pixels);
  g_free (base);
}

static void
test_writer_pick (void)
{
  gsize sz = scr_shm_total_size (16, 16);
  void *base = g_malloc0 (sz);
  uint32_t idx;

  scr_shm_header_init (base, 16, 16);
  /* Publish slot 0, then the next pick must avoid `latest' (0). */
  idx = scr_shm_writer_pick (base, SCR_SHM_SENTINEL);
  scr_shm_write_begin (base, idx);
  scr_shm_write_commit (base, idx);
  for (int i = 0; i < 100; i++)
    {
      uint32_t pick = scr_shm_writer_pick (base, idx);
      g_assert_cmpuint (pick, <, SCR_SHM_N_SLOTS);
      g_assert_cmpuint (pick, !=, idx);    /* never the just-published slot */
      scr_shm_write_begin (base, pick);
      scr_shm_write_commit (base, pick);
      idx = pick;
    }
  g_free (base);
}

/* ---- seqlock SPSC stress (the highest-value test) ------------------------ */

#define STRESS_W 96
#define STRESS_H 64

typedef struct
{
  void            *base;
  volatile gint    stop;
  volatile glong   reads, torn;
} StressCtx;

static gpointer
stress_writer (gpointer data)
{
  StressCtx *c = data;
  uint32_t last = SCR_SHM_SENTINEL;
  guint32 frame = 0;
  while (!g_atomic_int_get (&c->stop))
    {
      uint32_t idx = scr_shm_writer_pick (c->base, last);
      guint8 *px = scr_shm_write_begin (c->base, idx);
      /* Stamp the whole slot with one byte value; a coherent reader sees a
       * single uniform value across the slot. */
      memset (px, (int) (frame & 0xff), (gsize) STRESS_W * STRESS_H * 4);
      scr_shm_write_commit (c->base, idx);
      last = idx;
      frame++;
      /* ~5000 fps: contend hard but leave the reader coherent windows. */
      g_usleep (200);
    }
  return NULL;
}

static gpointer
stress_reader (gpointer data)
{
  StressCtx *c = data;
  guint64 last_gen = 0;
  while (!g_atomic_int_get (&c->stop))
    {
      ScrShmFrame f;
      const guint8 *px;
      guint8 v;
      gsize i, n = (gsize) STRESS_W * STRESS_H * 4;
      int uniform = 1;

      if (!scr_shm_read_acquire (c->base, &f))
        continue;
      if (f.generation == last_gen)
        continue;
      px = f.pixels;
      v = px[0];
      for (i = 1; i < n; i++)
        if (px[i] != v) { uniform = 0; break; }
      if (scr_shm_read_verify (c->base, &f))
        {
          c->reads++;
          if (!uniform)
            c->torn++;            /* verify said coherent but it tore == BUG */
          last_gen = f.generation;
        }
    }
  return NULL;
}

static void
test_seqlock_stress (void)
{
  StressCtx c = { 0 };
  GThread *w, *r;
  gsize sz = scr_shm_total_size (STRESS_W, STRESS_H);

  c.base = g_malloc0 (sz);
  scr_shm_header_init (c.base, STRESS_W, STRESS_H);

  w = g_thread_new ("w", stress_writer, &c);
  r = g_thread_new ("r", stress_reader, &c);
  g_usleep (2 * G_USEC_PER_SEC);
  g_atomic_int_set (&c.stop, 1);
  g_thread_join (w);
  g_thread_join (r);

  g_test_message ("seqlock: reads=%ld torn=%ld", c.reads, c.torn);
  g_assert_cmpint (c.torn, ==, 0);        /* never a torn frame past verify */
  g_assert_cmpint (c.reads, >, 100);      /* and frames actually flowed */
  g_free (c.base);
}

/* ---- JSON control vocabulary --------------------------------------------- */

static void
test_json_set_target (void)
{
  const gchar *args[] = { "--profile", "cool", "--orbit-radius", "60", NULL };
  ScrSetTarget in = { 0 }, out = { 0 };
  gchar *json;

  in.sink = 1;
  in.mon = (gchar *) "DP-11";
  in.so = (gchar *) "/lib/blackhole.so";
  in.args = (gchar **) args;
  in.w = 2560;
  in.h = 1440;
  in.covered = TRUE;

  json = scr_proto_build_set_target (&in);
  g_assert_nonnull (json);
  g_assert_true (scr_proto_parse_set_target (json, -1, &out));
  g_assert_cmpint (out.sink, ==, 1);
  g_assert_cmpstr (out.mon, ==, "DP-11");
  g_assert_cmpstr (out.so, ==, "/lib/blackhole.so");
  g_assert_cmpint (out.w, ==, 2560);
  g_assert_cmpint (out.h, ==, 1440);
  g_assert_true (out.covered);
  g_assert_nonnull (out.args);
  g_assert_cmpstr (out.args[0], ==, "--profile");
  g_assert_cmpstr (out.args[3], ==, "60");
  g_assert_null (out.args[4]);
  scr_set_target_clear (&out);
  g_free (json);
}

static void
test_json_set_target_empty_args (void)
{
  ScrSetTarget in = { 0 }, out = { 0 };
  gchar *json;

  in.sink = 0;
  in.mon = (gchar *) "eDP-1";
  in.so = (gchar *) "x.so";
  in.args = NULL;            /* no args */
  in.w = 1; in.h = 1;
  json = scr_proto_build_set_target (&in);
  g_assert_true (scr_proto_parse_set_target (json, -1, &out));
  /* empty array round-trips to a NULL-terminated empty vector or NULL. */
  if (out.args != NULL)
    g_assert_null (out.args[0]);
  scr_set_target_clear (&out);
  g_free (json);

  /* Missing required fields -> rejected. */
  g_assert_false (scr_proto_parse_set_target ("{\"t\":\"set-target\"}", -1, &out));
  scr_set_target_clear (&out);
}

static void
test_json_frame_buffer (void)
{
  ScrFrameBuffer in = { 0 }, out = { 0 };
  gchar *json;

  in.sink = 0; in.mon = (gchar *) "HDMI-A-1";
  in.w = 1920; in.h = 1080; in.stride = 1920 * 4; in.slots = 3;
  json = scr_proto_build_frame_buffer (&in);
  g_assert_true (scr_proto_parse_frame_buffer (json, -1, &out));
  g_assert_cmpint (out.sink, ==, 0);
  g_assert_cmpstr (out.mon, ==, "HDMI-A-1");
  g_assert_cmpint (out.w, ==, 1920);
  g_assert_cmpint (out.stride, ==, 1920 * 4);
  g_assert_cmpint (out.slots, ==, 3);
  scr_frame_buffer_clear (&out);
  g_free (json);
}

static void
test_json_load_result (void)
{
  ScrLoadResult in = { 0 }, out = { 0 };
  gchar *json;

  in.sink = 1; in.mon = (gchar *) "DP-2"; in.ok = FALSE;
  in.err = (gchar *) "bad --infall value";
  json = scr_proto_build_load_result (&in);
  g_assert_true (scr_proto_parse_load_result (json, -1, &out));
  g_assert_cmpint (out.sink, ==, 1);
  g_assert_false (out.ok);
  g_assert_cmpstr (out.err, ==, "bad --infall value");
  scr_load_result_clear (&out);
  g_free (json);

  /* ok case: err is NULL. */
  in.ok = TRUE; in.err = NULL;
  json = scr_proto_build_load_result (&in);
  g_assert_true (scr_proto_parse_load_result (json, -1, &out));
  g_assert_true (out.ok);
  g_assert_null (out.err);
  scr_load_result_clear (&out);
  g_free (json);
}

static void
test_json_scalars (void)
{
  int fps = 0, ver = 0, sink = 0;
  gboolean paused = FALSE;
  gchar *json, *mon = NULL;

  json = scr_proto_build_set_fps (24);
  g_assert_true (scr_proto_parse_set_fps (json, -1, &fps));
  g_assert_cmpint (fps, ==, 24);
  g_free (json);

  json = scr_proto_build_pause (TRUE);
  g_assert_true (scr_proto_parse_pause (json, -1, &paused));
  g_assert_true (paused);
  g_free (json);

  json = scr_proto_build_hello (SCR_PROTO_VERSION);
  g_assert_true (scr_proto_parse_hello (json, -1, &ver));
  g_assert_cmpint (ver, ==, SCR_PROTO_VERSION);
  g_free (json);

  json = scr_proto_build_remove_target (1, "DP-9");
  g_assert_true (scr_proto_parse_remove_target (json, -1, &sink, &mon));
  g_assert_cmpint (sink, ==, 1);
  g_assert_cmpstr (mon, ==, "DP-9");
  g_free (mon);
  g_free (json);
}

static void
test_json_type_and_malformed (void)
{
  gchar *t;

  t = scr_proto_message_type ("{\"t\":\"ping\"}", -1);
  g_assert_cmpstr (t, ==, "ping");
  g_free (t);

  /* Malformed / wrong-type inputs never crash and return NULL/FALSE. */
  g_assert_null (scr_proto_message_type ("not json", -1));
  g_assert_null (scr_proto_message_type ("[1,2,3]", -1));
  g_assert_null (scr_proto_message_type ("", -1));
  g_assert_null (scr_proto_message_type ("{\"x\":1}", -1));   /* no "t" */

  {
    int fps = 99;
    g_assert_false (scr_proto_parse_set_fps ("garbage", -1, &fps));
    g_assert_false (scr_proto_parse_set_fps ("{\"t\":\"pause\"}", -1, &fps));
  }
}

/* ---- real SCM_RIGHTS fd passing over SEQPACKET --------------------------- */

static void
test_fd_passing (void)
{
  int sv[2];
  GSocket *a, *b;
  GError *err = NULL;
  int memfd;
  gsize sz = scr_shm_total_size (8, 8);
  void *base;
  GOutputVector ov;
  GSocketControlMessage *cm;
  guint8 rbuf[256];
  GInputVector iv;
  GSocketControlMessage **rcm = NULL;
  gint n_rcm = 0, flags = 0;
  gssize n;
  int got_fd = -1;
  void *map2;

  g_assert_cmpint (socketpair (AF_UNIX, SOCK_SEQPACKET, 0, sv), ==, 0);
  a = g_socket_new_from_fd (sv[0], &err);
  g_assert_no_error (err);
  b = g_socket_new_from_fd (sv[1], &err);
  g_assert_no_error (err);

  /* Create + init a memfd, stamp a marker into slot 0. */
  memfd = memfd_create ("test", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  g_assert_cmpint (memfd, >=, 0);
  g_assert_cmpint (ftruncate (memfd, (off_t) sz), ==, 0);
  base = mmap (NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0);
  g_assert_true (base != MAP_FAILED);
  scr_shm_header_init (base, 8, 8);
  ((guint8 *) scr_shm_slot_ptr (base, 0))[0] = 0xAB;

  /* Send a frame-buffer announce + the memfd. */
  {
    ScrFrameBuffer fb = { 0, (gchar *) "M", 8, 8, 32, 3 };
    gchar *json = scr_proto_build_frame_buffer (&fb);
    GUnixFDMessage *fdm = G_UNIX_FD_MESSAGE (g_unix_fd_message_new ());
    g_assert_true (g_unix_fd_message_append_fd (fdm, memfd, &err));
    g_assert_no_error (err);
    cm = G_SOCKET_CONTROL_MESSAGE (fdm);
    ov.buffer = json; ov.size = strlen (json);
    n = g_socket_send_message (a, NULL, &ov, 1, &cm, 1, 0, NULL, &err);
    g_assert_no_error (err);
    g_assert_cmpint (n, >, 0);
    g_object_unref (cm);
    g_free (json);
  }

  /* Receive it, steal the fd. */
  iv.buffer = rbuf; iv.size = sizeof rbuf;
  n = g_socket_receive_message (b, NULL, &iv, 1, &rcm, &n_rcm, &flags, NULL, &err);
  g_assert_no_error (err);
  g_assert_cmpint (n, >, 0);
  g_assert_cmpint (n_rcm, ==, 1);
  g_assert_true (G_IS_UNIX_FD_MESSAGE (rcm[0]));
  {
    gint nf = 0;
    gint *fds = g_unix_fd_message_steal_fds (G_UNIX_FD_MESSAGE (rcm[0]), &nf);
    g_assert_cmpint (nf, ==, 1);
    got_fd = fds[0];
    g_free (fds);
  }
  g_object_unref (rcm[0]);
  g_free (rcm);
  g_assert_cmpint (got_fd, >=, 0);

  /* The received fd maps the SAME memory: see the marker the sender wrote. */
  map2 = mmap (NULL, sz, PROT_READ, MAP_SHARED, got_fd, 0);
  g_assert_true (map2 != MAP_FAILED);
  g_assert_true (scr_shm_header_validate (map2, 8, 8));
  g_assert_cmpuint (((const guint8 *) scr_shm_slot_ptr (map2, 0))[0], ==, 0xAB);

  munmap (map2, sz);
  munmap (base, sz);
  close (got_fd);
  close (memfd);
  g_object_unref (a);
  g_object_unref (b);
}

static void
test_memfd_sealing (void)
{
  gsize sz = scr_shm_total_size (32, 32);
  int fd = memfd_create ("seal", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  g_assert_cmpint (fd, >=, 0);
  g_assert_cmpint (ftruncate (fd, (off_t) sz), ==, 0);
  g_assert_cmpint (fcntl (fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW), ==, 0);
  /* After sealing the size, shrinking must fail (would SIGBUS the reader). */
  g_assert_cmpint (ftruncate (fd, (off_t) (sz / 2)), !=, 0);
  close (fd);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/screensaver/layout", test_layout);
  g_test_add_func ("/screensaver/total-size", test_total_size);
  g_test_add_func ("/screensaver/header", test_header_init_validate);
  g_test_add_func ("/screensaver/read-empty", test_read_acquire_empty);
  g_test_add_func ("/screensaver/writer-pick", test_writer_pick);
  g_test_add_func ("/screensaver/seqlock-stress", test_seqlock_stress);
  g_test_add_func ("/screensaver/json/set-target", test_json_set_target);
  g_test_add_func ("/screensaver/json/set-target-empty", test_json_set_target_empty_args);
  g_test_add_func ("/screensaver/json/frame-buffer", test_json_frame_buffer);
  g_test_add_func ("/screensaver/json/load-result", test_json_load_result);
  g_test_add_func ("/screensaver/json/scalars", test_json_scalars);
  g_test_add_func ("/screensaver/json/malformed", test_json_type_and_malformed);
  g_test_add_func ("/screensaver/fd-passing", test_fd_passing);
  g_test_add_func ("/screensaver/memfd-sealing", test_memfd_sealing);
  return g_test_run ();
}
