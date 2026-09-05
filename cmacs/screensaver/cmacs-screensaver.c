/* cmacs-screensaver.c --- drive the out-of-process screensaver renderer.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Rendering happens in a separate process (cmacs-screensaver-render) with its
 * own GL context, so it can never lag Emacs's main thread or hang the gowl
 * dispatch thread, and the in-process raylib(GLX)/gowl(EGL) context conflict
 * disappears.  This file is the Emacs-side manager:
 *
 *   - spawns + supervises the child over a SOCK_SEQPACKET control socket
 *     (length-delimited JSON datagrams; see cmacs-screensaver-proto.h),
 *   - snapshots gowl monitor geometry (under the gowl lock) and tells the child
 *     which (sink, monitor) targets to render and at what size / covered state,
 *   - receives each target's shared-memory frame buffer (a memfd over SCM_RIGHTS),
 *     maps it read-only, and on a light GLib timer pushes the newest complete
 *     frame into gowl (gowl copies it).  No GL ever runs on the Emacs thread.
 *
 * "Buffer" playback stays in-process (pure Elisp via cmacs-libregnum-play); only
 * the WALLPAPER and LOCK sinks use the child.  gowl still only ever sees raw
 * ARGB8888 pixels -- it never links libregnum. */

#include <config.h>

#ifdef HAVE_CMACS_SCREENSAVER

#include "lisp.h"
#include "cmacs-screensaver.h"
#include "cmacs-screensaver-proto.h"
#include "cmacs-glib-loop.h"

#include <glib.h>
#include <gio/gio.h>
#include <gio/gunixfdmessage.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/stat.h>

#ifdef HAVE_CMACS_GOWL
#include "cmacs-gowl.h"
#include <gowl.h>
#endif

/* ---- tunables ------------------------------------------------------------ */

#define SCR_FPS_DEFAULT          30
#define SCR_START_TIMEOUT_DEFAULT (3 * G_USEC_PER_SEC) /* bounded load wait */
#define SCR_HEARTBEAT_STALE_US   (3 * G_USEC_PER_SEC) /* wedge threshold */
#define SCR_WATCHDOG_MS          1000
#define SCR_RESTART_WINDOW_US    (30 * G_USEC_PER_SEC)
#define SCR_RESTART_MAX          5     /* failures per window before give-up */
#define SCR_RESTART_BASE_MS      250
#define SCR_RESTART_CAP_MS       5000

/* ---- per-sink session (the desired config) ------------------------------- */

typedef struct
{
  int    active;
  int    is_lock;
  char  *so_path;        /* owned */
  char **argv;           /* owned, NULL-terminated, or NULL */
  int    pause_covered;
} ScrSession;

/* ---- per (sink, monitor) target ------------------------------------------ */

typedef struct
{
  int      sink;
  char    *mon;          /* owned */
  int      w, h;         /* last geometry we told the child */
  int      covered;      /* last covered flag we told the child */
  int      memfd;        /* received frame-buffer fd, or -1 */
  void    *map;          /* read-only mmap of the frame ring, or NULL */
  gsize    map_size;
  guint64  last_pushed_gen;
  gint64   last_advance_us;
} ScrTarget;

/* ---- render child -------------------------------------------------------- */

typedef struct
{
  GSocket *sock;             /* parent end of the control socketpair */
  GSource *io_source;        /* recv watch (on the cmacs GMainContext) */
  GPid     pid;
  guint    child_watch;
  guint    watchdog_source;
  guint    respawn_source;   /* backoff timer, or 0 */
  gint64   last_heartbeat_us;
  gint64   last_watchdog_us;   /* when the watchdog itself last ran */
  int      restart_count;    /* within the current window */
  gint64   restart_window_us;
  gboolean gave_up;
  gboolean alive;
} ScrChild;

/* ---- handshake (bounded synchronous wait for the first load-result) ------ */

typedef struct
{
  gboolean  waiting;
  gboolean  got;
  gboolean  ok;
  int       sink;
  char     *mon;             /* the target we're waiting on (owned) */
  char     *err;             /* owned on failure */
} ScrHandshake;

/* ---- globals ------------------------------------------------------------- */

static ScrSession   sessions[CMACS_SCREENSAVER_N_SINKS];
/* The TEXTURE sink has no monitors, so it has exactly one target under a
   fixed key, and the caller owns its size. */
#define SCR_TEXTURE_MON "texture"
static int texture_w, texture_h;
static GHashTable  *targets;            /* "sink:mon" -> ScrTarget* */
static ScrChild     child_proc;
static ScrHandshake handshake;
static guint        pump_source_id;
static int          pump_fps = SCR_FPS_DEFAULT;
static int          child_paused;       /* last pause state sent */
static char        *scr_last_error;     /* latched, for `status' */
static gint64       scr_start_timeout_us = SCR_START_TIMEOUT_DEFAULT;

/* ---- forward decls ------------------------------------------------------- */

static void scr_child_teardown (void);
static gboolean scr_child_spawn (char **err_out);
static void scr_child_send_str (gchar *json /* takes ownership */);
static void scr_targets_clear_all (void);
static void scr_resync_all (void);
static void scr_ensure_pump (void);

/* ---- target table -------------------------------------------------------- */

static gchar *
target_key (int sink, const char *mon)
{
  return g_strdup_printf ("%d:%s", sink, mon);
}

static void
target_unmap (ScrTarget *t)
{
  if (t->map != NULL && t->map != MAP_FAILED)
    munmap (t->map, t->map_size);
  t->map = NULL;
  t->map_size = 0;
  if (t->memfd >= 0)
    close (t->memfd);
  t->memfd = -1;
  t->last_pushed_gen = 0;
}

#ifdef HAVE_CMACS_GOWL
static void scr_gowl_clear_target (ScrTarget *t);
#endif

static void
target_free (gpointer data)
{
  ScrTarget *t = data;
  if (t == NULL)
    return;
#ifdef HAVE_CMACS_GOWL
  scr_gowl_clear_target (t);
#endif
  target_unmap (t);
  g_free (t->mon);
  g_free (t);
}

static GHashTable *
targets_table (void)
{
  if (targets == NULL)
    targets = g_hash_table_new_full (g_str_hash, g_str_equal,
                                     g_free, target_free);
  return targets;
}

/* ---- gowl frame push (only place that touches gowl) ---------------------- */

#ifdef HAVE_CMACS_GOWL

static void
scr_gowl_clear_target (ScrTarget *t)
{
  GowlCompositor *comp = cmacs_gowl_get_compositor ();
  if (comp == NULL)
    return;
  cmacs_gowl_lock ();
  if (t->sink == CMACS_SCREENSAVER_LOCK)
    gowl_compositor_clear_lock_frame (comp, t->mon);
  else
    gowl_compositor_clear_wallpaper_frame (comp, t->mon);
  cmacs_gowl_unlock ();
}

/* Push one target's newest complete frame to gowl, if there is a new one.
 * Returns TRUE if a frame was pushed. */
static gboolean
scr_gowl_push_target (ScrTarget *t, GowlCompositor *comp)
{
  ScrShmFrame f;

  if (t->map == NULL)
    return FALSE;
  if (!scr_shm_read_acquire (t->map, &f))
    return FALSE;                         /* no frame yet / writer mid-write */
  if (f.generation == t->last_pushed_gen)
    return FALSE;                         /* nothing new since last push */

  cmacs_gowl_lock ();
  if (t->sink == CMACS_SCREENSAVER_LOCK)
    gowl_compositor_push_lock_frame (comp, t->mon, f.pixels,
                                     t->w, t->h, t->w * 4);
  else
    gowl_compositor_push_wallpaper_frame (comp, t->mon, f.pixels,
                                          t->w, t->h, t->w * 4);
  cmacs_gowl_unlock ();

  /* gowl copied the pixels; only advance our cursor if the slot didn't tear
   * underneath the copy (extremely rare -- 3 slots + a full GL frame to lap). */
  if (scr_shm_read_verify (t->map, &f))
    {
      t->last_pushed_gen = f.generation;
      t->last_advance_us = g_get_monotonic_time ();
    }
  return TRUE;
}

#endif /* HAVE_CMACS_GOWL */

/* ---- child: binary resolution ------------------------------------------- */

static const char *
scr_resolve_binary (void)
{
  const char *env = g_getenv ("CMACS_SCREENSAVER_RENDER_BIN");
  if (env != NULL && *env != '\0' && g_file_test (env, G_FILE_TEST_IS_EXECUTABLE))
    return env;
#ifdef CMACS_SCREENSAVER_RENDER_INSTALLED
  if (g_file_test (CMACS_SCREENSAVER_RENDER_INSTALLED, G_FILE_TEST_IS_EXECUTABLE))
    return CMACS_SCREENSAVER_RENDER_INSTALLED;
#endif
  return NULL;
}

/* ---- child: control sends ------------------------------------------------ */

/* Send a JSON datagram (no fd).  Non-blocking + best-effort: a dead/full socket
 * never blocks Emacs's main thread. */
static void
scr_child_send_str (gchar *json)
{
  if (json == NULL)
    return;
  if (child_proc.sock != NULL)
    g_socket_send (child_proc.sock, json, strlen (json),
                   NULL, NULL);          /* errors ignored: watchdog/EOF handle */
  g_free (json);
}

static void
scr_child_send_set_target (int sink, const char *mon, const char *so,
                           char **argv, int w, int h, int covered)
{
  ScrSetTarget st = { 0 };
  st.sink = sink;
  st.mon = (char *) mon;
  st.so = (char *) so;
  st.args = argv;
  st.w = w;
  st.h = h;
  st.covered = covered ? TRUE : FALSE;
  scr_child_send_str (scr_proto_build_set_target (&st));
}

/* ---- child: receive ------------------------------------------------------ */

/* Map a freshly-announced frame buffer for (SINK, MON) onto FD. */
static void
scr_child_on_frame_buffer (const ScrFrameBuffer *fb, int fd)
{
  gchar *key;
  ScrTarget *t;
  gsize size;
  void *map;
  int flags;

  if (fd < 0)
    return;
  if (!scr_shm_dims_valid ((uint32_t) fb->w, (uint32_t) fb->h))
    {
      close (fd);
      return;
    }
  /* Defensive: keep the received fd close-on-exec (GLib normally does this). */
  flags = fcntl (fd, F_GETFD);
  if (flags >= 0)
    fcntl (fd, F_SETFD, flags | FD_CLOEXEC);

  size = scr_shm_total_size ((uint32_t) fb->w, (uint32_t) fb->h);
  if (size == 0)
    {
      close (fd);
      return;
    }
  /* The announced dimensions and the fd travel separately; check that
     the fd really is that big before mapping it, or the first read past
     its end is a SIGBUS in the compositor's process rather than a
     dropped frame buffer. */
  {
    struct stat sb;
    if (fstat (fd, &sb) != 0 || sb.st_size < 0
        || (guint64) sb.st_size < size)
      {
        close (fd);
        return;
      }
  }
  map = mmap (NULL, size, PROT_READ, MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    {
      close (fd);
      return;
    }
  if (!scr_shm_header_validate (map, (uint32_t) fb->w, (uint32_t) fb->h))
    {
      munmap (map, size);
      close (fd);
      return;
    }

  key = target_key (fb->sink, fb->mon);
  t = g_hash_table_lookup (targets_table (), key);
  if (t == NULL)
    {
      t = g_new0 (ScrTarget, 1);
      t->sink = fb->sink;
      t->mon = g_strdup (fb->mon);
      t->memfd = -1;
      g_hash_table_insert (targets_table (), key, t);
    }
  else
    {
      target_unmap (t);                  /* drop a previous (resized) mapping */
      g_free (key);
    }
  t->w = fb->w;
  t->h = fb->h;
  t->memfd = fd;
  t->map = map;
  t->map_size = size;
  t->last_pushed_gen = 0;
  t->last_advance_us = g_get_monotonic_time ();
}

static void
scr_child_on_load_result (const ScrLoadResult *lr)
{
  g_clear_pointer (&scr_last_error, g_free);
  if (!lr->ok && lr->err != NULL)
    scr_last_error = g_strdup (lr->err);

  if (handshake.waiting && handshake.sink == lr->sink
      && g_strcmp0 (handshake.mon, lr->mon) == 0)
    {
      handshake.got = TRUE;
      handshake.ok = lr->ok;
      g_clear_pointer (&handshake.err, g_free);
      if (!lr->ok)
        handshake.err = g_strdup (lr->err ? lr->err : "module load failed");
    }
}

/* Process one already-received datagram (+ optional fd). */
static void
scr_child_dispatch (const gchar *json, gssize len, int fd)
{
  gchar *type = scr_proto_message_type (json, len);

  if (type == NULL)
    {
      if (fd >= 0)
        close (fd);
      return;
    }

  if (g_strcmp0 (type, SCR_MSG_FRAME_BUFFER) == 0)
    {
      ScrFrameBuffer fb;
      if (scr_proto_parse_frame_buffer (json, len, &fb))
        {
          scr_child_on_frame_buffer (&fb, fd);
          fd = -1;                        /* ownership transferred / closed */
          scr_frame_buffer_clear (&fb);
        }
    }
  else if (g_strcmp0 (type, SCR_MSG_LOAD_RESULT) == 0)
    {
      ScrLoadResult lr;
      if (scr_proto_parse_load_result (json, len, &lr))
        {
          scr_child_on_load_result (&lr);
          scr_load_result_clear (&lr);
        }
    }
  else if (g_strcmp0 (type, SCR_MSG_HEARTBEAT) == 0)
    {
      child_proc.last_heartbeat_us = g_get_monotonic_time ();
    }
  /* hello-ack / pong / stopped: no action needed beyond liveness tracking */

  if (fd >= 0)
    close (fd);
  g_free (type);
}

/* Receive one datagram from the child.  Returns 1 if a message was processed,
 * 0 on would-block, -1 on EOF / fatal error. */
static int
scr_child_recv_one (void)
{
  guint8 buf[SCR_MSG_MAX_BYTES];
  GInputVector iv;
  GSocketControlMessage **cmsgs = NULL;
  gint n_cmsgs = 0, flags = 0, i;
  GError *err = NULL;
  gssize n;
  int fd = -1;

  if (child_proc.sock == NULL)
    return -1;

  iv.buffer = buf;
  iv.size = sizeof buf;
  n = g_socket_receive_message (child_proc.sock, NULL, &iv, 1,
                                &cmsgs, &n_cmsgs, &flags, NULL, &err);

  for (i = 0; i < n_cmsgs; i++)
    {
      if (fd < 0 && G_IS_UNIX_FD_MESSAGE (cmsgs[i]))
        {
          gint nf = 0;
          gint *fds = g_unix_fd_message_steal_fds (
                        G_UNIX_FD_MESSAGE (cmsgs[i]), &nf);
          gint k;
          if (nf > 0)
            fd = fds[0];
          for (k = 1; k < nf; k++)
            close (fds[k]);              /* announce carries exactly one fd */
          g_free (fds);
        }
      g_object_unref (cmsgs[i]);
    }
  g_free (cmsgs);

  if (n == 0)
    return -1;                            /* orderly EOF */
  if (n < 0)
    {
      gboolean wb = g_error_matches (err, G_IO_ERROR, G_IO_ERROR_WOULD_BLOCK);
      g_clear_error (&err);
      if (fd >= 0)
        close (fd);
      return wb ? 0 : -1;
    }

  scr_child_dispatch ((const gchar *) buf, n, fd);
  return 1;
}

static gboolean
scr_child_on_readable (GSocket *sock, GIOCondition cond, gpointer data)
{
  (void) sock;
  (void) data;

  if (cond & (G_IO_HUP | G_IO_ERR | G_IO_NVAL))
    {
      /* The child_watch handler does the actual teardown/respawn. */
      return G_SOURCE_REMOVE;
    }
  for (;;)
    {
      int r = scr_child_recv_one ();
      if (r <= 0)
        return r == 0 ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
    }
}

/* ---- child: lifecycle ---------------------------------------------------- */

static int
scr_any_session_active (void)
{
  int i;
  for (i = 0; i < CMACS_SCREENSAVER_N_SINKS; i++)
    if (sessions[i].active)
      return 1;
  return 0;
}

static void scr_child_schedule_respawn (void);

static void
scr_child_on_exit (GPid pid, gint status, gpointer data)
{
  (void) status;
  (void) data;

  g_spawn_close_pid (pid);
  child_proc.pid = 0;
  child_proc.alive = FALSE;

  /* Drop the recv source + socket; mappings from the dead child are useless. */
  if (child_proc.io_source != NULL)
    {
      g_source_destroy (child_proc.io_source);
      g_clear_pointer (&child_proc.io_source, g_source_unref);
    }
  if (child_proc.sock != NULL)
    {
      g_socket_close (child_proc.sock, NULL);
      g_clear_object (&child_proc.sock);
    }
  child_proc.child_watch = 0;            /* GLib removes the watch after this */
  scr_targets_clear_all ();

  if (scr_any_session_active () && !child_proc.gave_up)
    scr_child_schedule_respawn ();
}

static gboolean
scr_child_respawn_cb (gpointer data)
{
  char *err = NULL;
  (void) data;

  child_proc.respawn_source = 0;
  if (!scr_any_session_active () || child_proc.gave_up)
    return G_SOURCE_REMOVE;

  if (scr_child_spawn (&err))
    {
      scr_resync_all ();                  /* re-apply every active target */
    }
  else
    {
      g_clear_pointer (&scr_last_error, g_free);
      scr_last_error = err ? err : g_strdup ("respawn failed");
      scr_child_schedule_respawn ();      /* counts as another failure */
    }
  return G_SOURCE_REMOVE;
}

static void
scr_child_schedule_respawn (void)
{
  gint64 now = g_get_monotonic_time ();
  guint delay_ms;
  int shift;

  if (child_proc.respawn_source != 0)
    return;

  if (now - child_proc.restart_window_us > SCR_RESTART_WINDOW_US)
    {
      child_proc.restart_window_us = now;
      child_proc.restart_count = 0;
    }
  child_proc.restart_count++;
  if (child_proc.restart_count > SCR_RESTART_MAX)
    {
      child_proc.gave_up = TRUE;
      g_clear_pointer (&scr_last_error, g_free);
      scr_last_error = g_strdup ("render child crash-looped; gave up "
                                 "(reveal static wallpaper)");
      return;
    }

  shift = child_proc.restart_count - 1;
  if (shift > 5)
    shift = 5;
  delay_ms = SCR_RESTART_BASE_MS << shift;
  if (delay_ms > SCR_RESTART_CAP_MS)
    delay_ms = SCR_RESTART_CAP_MS;
  child_proc.respawn_source =
    g_timeout_add (delay_ms, scr_child_respawn_cb, NULL);
}

/* Periodic watchdog: a child that stops heartbeating while it should be running
 * is wedged -- kill it so the child_watch handler restarts it.
 *
 * "Stops heartbeating" has to mean the CHILD went quiet, not that WE
 * stopped listening.  Heartbeats are read on the cmacs GMainContext, and
 * anything running a nested loop on Emacs's thread -- a GTK context
 * menu, a modal dialog, a long synchronous eval -- stops that context
 * dead.  The child keeps sending; nobody reads.  When the loop resumes,
 * a naive staleness test sees a multi-second gap and SIGKILLs a
 * perfectly healthy child.  Right-clicking the second-brain graph did
 * exactly that, and a few menus in a row exhausted SCR_RESTART_MAX and
 * gave up for good, so the background never came back.
 *
 * So the watchdog also times ITSELF.  A gap much longer than its own
 * interval means our loop was blocked, and the child's silence across
 * that window is no evidence at all -- forgive exactly that much and
 * wait for the next honest interval. */
static gboolean
scr_child_watchdog_cb (gpointer data)
{
  gint64 now = g_get_monotonic_time ();
  gint64 since_tick;
  (void) data;

  since_tick = (child_proc.last_watchdog_us != 0)
                 ? now - child_proc.last_watchdog_us : 0;
  child_proc.last_watchdog_us = now;

  /* Twice the interval: ordinary jitter is well under that, and a
     nested loop is normally far over it. */
  if (since_tick > 2 * SCR_WATCHDOG_MS * 1000)
    {
      child_proc.last_heartbeat_us += since_tick;
      if (child_proc.last_heartbeat_us > now)
        child_proc.last_heartbeat_us = now;
      return G_SOURCE_CONTINUE;
    }

  if (child_proc.alive && child_proc.pid != 0
      && !child_paused && scr_any_session_active ()
      && now - child_proc.last_heartbeat_us > SCR_HEARTBEAT_STALE_US)
    {
      g_clear_pointer (&scr_last_error, g_free);
      scr_last_error = g_strdup ("render child stopped responding; restarting");
      kill (child_proc.pid, SIGKILL);   /* child_watch -> respawn */
    }
  return G_SOURCE_CONTINUE;
}

static gboolean
scr_child_spawn (char **err_out)
{
  int sv[2];
  int fl;
  const char *bin;
  gchar *fdstr;
  gchar **envp;
  gchar *argv[2];
  GError *gerr = NULL;
  GPid pid = 0;

  bin = scr_resolve_binary ();
  if (bin == NULL)
    {
      *err_out = g_strdup ("cmacs-screensaver-render binary not found "
                           "(set CMACS_SCREENSAVER_RENDER_BIN)");
      return FALSE;
    }
  if (socketpair (AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv) != 0)
    {
      *err_out = g_strdup_printf ("socketpair: %s", g_strerror (errno));
      return FALSE;
    }
  /* Child end must survive exec (clear CLOEXEC); parent end keeps it. */
  fl = fcntl (sv[1], F_GETFD);
  if (fl >= 0)
    fcntl (sv[1], F_SETFD, fl & ~FD_CLOEXEC);

  fdstr = g_strdup_printf ("%d", sv[1]);
  envp = g_environ_setenv (g_get_environ (), "CMACS_SCREENSAVER_IPC_FD",
                           fdstr, TRUE);
  argv[0] = (gchar *) bin;
  argv[1] = NULL;

  if (!g_spawn_async (NULL, argv, envp,
                      G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_LEAVE_DESCRIPTORS_OPEN,
                      NULL, NULL, &pid, &gerr))
    {
      *err_out = g_strdup (gerr ? gerr->message : "spawn failed");
      g_clear_error (&gerr);
      g_free (fdstr);
      g_strfreev (envp);
      close (sv[0]);
      close (sv[1]);
      return FALSE;
    }
  g_free (fdstr);
  g_strfreev (envp);
  close (sv[1]);                          /* the child holds its own copy */

  child_proc.sock = g_socket_new_from_fd (sv[0], &gerr);
  if (child_proc.sock == NULL)
    {
      *err_out = g_strdup (gerr ? gerr->message : "socket wrap failed");
      g_clear_error (&gerr);
      close (sv[0]);
      g_spawn_close_pid (pid);
      kill (pid, SIGKILL);
      return FALSE;
    }
  g_socket_set_blocking (child_proc.sock, FALSE);

  child_proc.pid = pid;
  child_proc.alive = TRUE;
  child_proc.last_heartbeat_us = g_get_monotonic_time ();
  /* Baseline the self-timer too, so the first watchdog tick after a
     spawn is not mistaken for a stalled main loop. */
  child_proc.last_watchdog_us = child_proc.last_heartbeat_us;

  child_proc.io_source = g_socket_create_source (
                           child_proc.sock,
                           G_IO_IN | G_IO_HUP | G_IO_ERR, NULL);
  g_source_set_callback (child_proc.io_source,
                         G_SOURCE_FUNC (scr_child_on_readable), NULL, NULL);
  g_source_attach (child_proc.io_source, cmacs_glib_get_context ());

  child_proc.child_watch =
    g_child_watch_add (pid, scr_child_on_exit, NULL);

  if (child_proc.watchdog_source == 0)
    child_proc.watchdog_source =
      g_timeout_add (SCR_WATCHDOG_MS, scr_child_watchdog_cb, NULL);

  /* Handshake + initial config. */
  scr_child_send_str (scr_proto_build_hello (SCR_PROTO_VERSION));
  scr_child_send_str (scr_proto_build_set_fps (pump_fps));
  if (child_paused)
    scr_child_send_str (scr_proto_build_pause (TRUE));
  return TRUE;
}

static void
scr_child_teardown (void)
{
  if (child_proc.respawn_source != 0)
    {
      g_source_remove (child_proc.respawn_source);
      child_proc.respawn_source = 0;
    }
  if (child_proc.watchdog_source != 0)
    {
      g_source_remove (child_proc.watchdog_source);
      child_proc.watchdog_source = 0;
    }
  if (child_proc.io_source != NULL)
    {
      g_source_destroy (child_proc.io_source);
      g_clear_pointer (&child_proc.io_source, g_source_unref);
    }
  if (child_proc.pid != 0)
    {
      scr_child_send_str (scr_proto_build_simple (SCR_MSG_QUIT));
      kill (child_proc.pid, SIGTERM);
      if (child_proc.child_watch != 0)
        {
          g_source_remove (child_proc.child_watch);
          child_proc.child_watch = 0;
        }
      g_spawn_close_pid (child_proc.pid);
      child_proc.pid = 0;
    }
  if (child_proc.sock != NULL)
    {
      g_socket_close (child_proc.sock, NULL);
      g_clear_object (&child_proc.sock);
    }
  child_proc.alive = FALSE;
  child_proc.gave_up = FALSE;
  child_proc.restart_count = 0;
  scr_targets_clear_all ();
}

/* ---- targets: clear / resync against gowl monitors ----------------------- */

static void
scr_targets_clear_all (void)
{
  if (targets != NULL)
    g_hash_table_remove_all (targets);
}

/* Remove (and tell the child to drop) every target belonging to SINK. */
static void
scr_targets_remove_sink (int sink)
{
  GHashTableIter it;
  gpointer key, val;
  GList *drop = NULL, *l;

  if (targets == NULL)
    return;
  g_hash_table_iter_init (&it, targets);
  while (g_hash_table_iter_next (&it, &key, &val))
    {
      ScrTarget *t = val;
      if (t->sink == sink)
        drop = g_list_prepend (drop, g_strdup (t->mon));
    }
  for (l = drop; l != NULL; l = l->next)
    {
      gchar *k = target_key (sink, l->data);
      if (child_proc.sock != NULL)
        scr_child_send_str (scr_proto_build_remove_target (sink, l->data));
      g_hash_table_remove (targets, k);
      g_free (k);
      g_free (l->data);
    }
  g_list_free (drop);
}

#ifdef HAVE_CMACS_GOWL

typedef struct { char *name; int w, h; } ScrGeom;

/* Snapshot enabled monitors under the gowl lock (mirrors the old pump). */
static GArray *
scr_snapshot_monitors (GowlCompositor *comp)
{
  GArray *snap = g_array_new (FALSE, FALSE, sizeof (ScrGeom));
  GList *l;

  cmacs_gowl_lock ();
  for (l = gowl_compositor_get_monitors (comp); l != NULL; l = l->next)
    {
      GowlMonitor *mon = l->data;
      const char *name;
      ScrGeom g;
      int x, y;

      if (!gowl_monitor_get_enabled (mon))
        continue;
      name = gowl_monitor_get_name (mon);
      if (name == NULL)
        continue;
      gowl_monitor_get_geometry (mon, &x, &y, &g.w, &g.h);
      if (g.w <= 0 || g.h <= 0)
        continue;
      g.name = g_strdup (name);
      g_array_append_val (snap, g);
    }
  cmacs_gowl_unlock ();
  return snap;
}

/* For SINK's session, reconcile the child's targets with gowl's monitors:
 * create on appear, re-send on resize, update covered, drop on vanish. */
static void
scr_sync_sink (int sink, GowlCompositor *comp)
{
  ScrSession *s = &sessions[sink];
  GArray *snap;
  GHashTable *live;
  GHashTableIter it;
  gpointer key, val;
  GList *stale = NULL, *l;
  guint i;

  if (!s->active)
    return;

  snap = scr_snapshot_monitors (comp);
  live = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  for (i = 0; i < snap->len; i++)
    {
      ScrGeom *g = &g_array_index (snap, ScrGeom, i);
      gchar *k = target_key (sink, g->name);
      ScrTarget *t = g_hash_table_lookup (targets_table (), k);
      int covered = 0;

      g_hash_table_add (live, g_strdup (g->name));

      if (!s->is_lock && s->pause_covered)
        {
          cmacs_gowl_lock ();
          covered = gowl_compositor_monitor_bg_covered (comp, g->name) ? 1 : 0;
          cmacs_gowl_unlock ();
        }

      if (t == NULL)
        {
          /* New monitor: ask the child to render it.  The ScrTarget appears
           * Emacs-side when its frame-buffer is announced. */
          scr_child_send_set_target (sink, g->name, s->so_path, s->argv,
                                     g->w, g->h, covered);
        }
      else if (t->w != g->w || t->h != g->h)
        {
          /* Resized: drop the stale-size mapping now (don't push it), and ask
           * the child to re-create + re-announce at the new size. */
          target_unmap (t);
          t->w = g->w;
          t->h = g->h;
          t->covered = covered;
          scr_gowl_clear_target (t);
          scr_child_send_set_target (sink, g->name, s->so_path, s->argv,
                                     g->w, g->h, covered);
        }
      else if (t->covered != covered)
        {
          t->covered = covered;
          scr_child_send_set_target (sink, g->name, s->so_path, s->argv,
                                     g->w, g->h, covered);
        }
      g_free (k);
    }

  /* Monitors that vanished: drop their targets. */
  g_hash_table_iter_init (&it, targets_table ());
  while (g_hash_table_iter_next (&it, &key, &val))
    {
      ScrTarget *t = val;
      if (t->sink == sink && !g_hash_table_contains (live, t->mon))
        stale = g_list_prepend (stale, g_strdup (t->mon));
    }
  for (l = stale; l != NULL; l = l->next)
    {
      gchar *k = target_key (sink, l->data);
      scr_child_send_str (scr_proto_build_remove_target (sink, l->data));
      g_hash_table_remove (targets, k);
      g_free (k);
      g_free (l->data);
    }
  g_list_free (stale);

  for (i = 0; i < snap->len; i++)
    g_free (g_array_index (snap, ScrGeom, i).name);
  g_array_free (snap, TRUE);
  g_hash_table_destroy (live);
}

#endif /* HAVE_CMACS_GOWL */

/* Re-send every active session's targets after a (re)spawn. */
/* Ask the child to render the TEXTURE sink at the requested size.  No
   gowl, no monitor list: one target, one size, given by the caller. */
static void
scr_sync_texture (void)
{
  ScrSession *s = &sessions[CMACS_SCREENSAVER_TEXTURE];
  gchar *k;
  ScrTarget *t;

  if (!s->active || texture_w <= 0 || texture_h <= 0)
    return;

  k = target_key (CMACS_SCREENSAVER_TEXTURE, SCR_TEXTURE_MON);
  t = g_hash_table_lookup (targets_table (), k);
  g_free (k);

  if (t == NULL)
    scr_child_send_set_target (CMACS_SCREENSAVER_TEXTURE, SCR_TEXTURE_MON,
                               s->so_path, s->argv, texture_w, texture_h, 0);
  else if (t->w != texture_w || t->h != texture_h)
    {
      /* Drop the stale-size mapping rather than handing a consumer a
         frame whose dimensions no longer match what it asked for. */
      target_unmap (t);
      t->w = texture_w;
      t->h = texture_h;
      scr_child_send_set_target (CMACS_SCREENSAVER_TEXTURE, SCR_TEXTURE_MON,
                                 s->so_path, s->argv,
                                 texture_w, texture_h, 0);
    }
}

/* Re-send every active session's targets after a (re)spawn. */
static void
scr_resync_all (void)
{
#ifdef HAVE_CMACS_GOWL
  {
    GowlCompositor *comp = cmacs_gowl_get_compositor ();
    int i;
    if (comp != NULL)
      for (i = 0; i < 2; i++)
        if (sessions[i].active)
          scr_sync_sink (i, comp);
  }
#endif
  scr_sync_texture ();
}

/* ---- pump (drain shm -> gowl) -------------------------------------------- */

static gboolean
scr_pump_tick (gpointer data)
{
  int any = 0;
  (void) data;

#ifdef HAVE_CMACS_GOWL
  {
    GowlCompositor *comp = cmacs_gowl_get_compositor ();
    GHashTableIter it;
    gpointer key, val;
    int i;

    if (comp == NULL)
      goto done;

    /* The lock background follows the compositor's lock state. */
    if (sessions[CMACS_SCREENSAVER_LOCK].active)
      {
        gboolean locked;
        cmacs_gowl_lock ();
        locked = gowl_compositor_is_locked (comp);
        cmacs_gowl_unlock ();
        if (!locked)
          cmacs_screensaver_stop (CMACS_SCREENSAVER_LOCK);
      }

    for (i = 0; i < 2; i++)
      if (sessions[i].active)
        {
          any = 1;
          scr_sync_sink (i, comp);
        }

    if (targets != NULL)
      {
        g_hash_table_iter_init (&it, targets);
        while (g_hash_table_iter_next (&it, &key, &val))
          scr_gowl_push_target (val, comp);
      }
  }
done:
#endif

  /* The TEXTURE sink needs no gowl and no push: the consumer pulls with
     cmacs_screensaver_peek_frame.  All the pump owes it is keeping the
     target in sync and the source alive. */
  if (sessions[CMACS_SCREENSAVER_TEXTURE].active)
    {
      any = 1;
      scr_sync_texture ();
    }

  if (!any)
    {
      pump_source_id = 0;
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

static void
scr_ensure_pump (void)
{
  GSource *src;
  guint interval;

  if (pump_source_id != 0)
    return;
  interval = (guint) (1000 / (pump_fps > 0 ? pump_fps : SCR_FPS_DEFAULT));
  if (interval < 1)
    interval = 1;
  src = g_timeout_source_new (interval);
  g_source_set_callback (src, scr_pump_tick, NULL, NULL);
  pump_source_id = g_source_attach (src, cmacs_glib_get_context ());
  g_source_unref (src);
}

static void
scr_restart_pump (void)
{
  if (pump_source_id != 0)
    {
      GSource *s = g_main_context_find_source_by_id (cmacs_glib_get_context (),
                                                     pump_source_id);
      if (s != NULL)
        g_source_destroy (s);
      pump_source_id = 0;
    }
  if (scr_any_session_active ())
    scr_ensure_pump ();
}

/* ---- bounded start handshake -------------------------------------------- */

#ifdef HAVE_CMACS_GOWL
/* After sending the initial set-targets for SINK, block (bounded) on the child
 * socket until the first target's load-result arrives, so a bad module reports
 * synchronously.  Blocks ONLY on the screensaver socket (never pumps the cmacs
 * context, so no re-entrant Lisp), up to SCR_START_TIMEOUT_US.  Returns a
 * newly-allocated error string on failure, or NULL on success / timeout. */
static char *
scr_wait_first_load (int sink)
{
  gint64 deadline = g_get_monotonic_time () + scr_start_timeout_us;
  GHashTableIter it;
  gpointer key, val;
  char *first_mon = NULL;
  char *err = NULL;

  /* Pick any monitor of this sink to wait on (they load the same module). */
  if (targets != NULL)
    {
      g_hash_table_iter_init (&it, targets);
      while (g_hash_table_iter_next (&it, &key, &val))
        {
          ScrTarget *t = val;
          if (t->sink == sink)
            {
              first_mon = g_strdup (t->mon);
              break;
            }
        }
    }
  /* No target appeared yet (announce not received); wait on the sink generally
   * by matching the first load-result for this sink. */

  handshake.waiting = TRUE;
  handshake.got = FALSE;
  handshake.ok = FALSE;
  handshake.sink = sink;
  g_clear_pointer (&handshake.mon, g_free);
  handshake.mon = first_mon;             /* may be NULL -> match-any below */
  g_clear_pointer (&handshake.err, g_free);

  while (!handshake.got)
    {
      gint64 now = g_get_monotonic_time ();
      gint64 remain = deadline - now;
      GError *werr = NULL;

      if (remain <= 0)
        break;                            /* timeout: leave async */
      if (child_proc.sock == NULL)
        break;
      if (!g_socket_condition_timed_wait (child_proc.sock, G_IO_IN,
                                          remain, NULL, &werr))
        {
          gboolean to = g_error_matches (werr, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
          g_clear_error (&werr);
          if (to)
            break;
          break;                          /* error: leave async */
        }
      /* Drain whatever arrived. */
      for (;;)
        {
          int r = scr_child_recv_one ();
          if (r <= 0)
            break;
        }
      /* If we didn't yet know the monitor name, accept the first load-result
       * for this sink (on_load_result matches mon when set; when NULL it never
       * matches, so fall back here). */
      if (!handshake.got && handshake.mon == NULL && scr_last_error != NULL)
        {
          /* a failure was latched for this sink during drain */
          handshake.got = TRUE;
          handshake.ok = FALSE;
          handshake.err = g_strdup (scr_last_error);
        }
    }

  if (handshake.got && !handshake.ok)
    err = g_strdup (handshake.err ? handshake.err : "module load failed");

  handshake.waiting = FALSE;
  g_clear_pointer (&handshake.mon, g_free);
  g_clear_pointer (&handshake.err, g_free);
  return err;
}
#endif /* HAVE_CMACS_GOWL */

/* ---- public API ---------------------------------------------------------- */

char *
cmacs_screensaver_start_texture (const char *so_path, const char *const *argv,
                                 int fps, int w, int h)
{
  ScrSession *s;
  char *serr;

  if (so_path == NULL)
    return g_strdup ("invalid screensaver module");
  if (!scr_shm_dims_valid ((uint32_t) w, (uint32_t) h))
    return g_strdup_printf ("invalid screensaver size %dx%d", w, h);

  if (fps > 0)
    pump_fps = fps;

  child_proc.gave_up = FALSE;
  if (child_proc.pid == 0 && child_proc.respawn_source == 0)
    {
      char *serr2 = NULL;
      if (!scr_child_spawn (&serr2))
        return serr2 ? serr2 : g_strdup ("could not start render child");
    }

  s = &sessions[CMACS_SCREENSAVER_TEXTURE];
  if (s->active)
    scr_targets_remove_sink (CMACS_SCREENSAVER_TEXTURE);
  g_clear_pointer (&s->so_path, g_free);
  g_clear_pointer (&s->argv, g_strfreev);
  s->active = 1;
  s->is_lock = 0;
  s->pause_covered = 0;
  s->so_path = g_strdup (so_path);
  s->argv = (argv != NULL) ? g_strdupv ((char **) argv) : NULL;
  texture_w = w;
  texture_h = h;

  scr_child_send_str (scr_proto_build_set_fps (pump_fps));
  scr_sync_texture ();

  /* Same synchronous error UX as the other sinks: a module that will
     not load should say so now, not fail silently into a blank
     background. */
  serr = scr_wait_first_load (CMACS_SCREENSAVER_TEXTURE);
  if (serr != NULL)
    {
      cmacs_screensaver_stop (CMACS_SCREENSAVER_TEXTURE);
      return serr;
    }

  scr_ensure_pump ();
  return NULL;
}

void
cmacs_screensaver_texture_resize (int w, int h)
{
  if (!sessions[CMACS_SCREENSAVER_TEXTURE].active)
    return;
  if (!scr_shm_dims_valid ((uint32_t) w, (uint32_t) h))
    return;
  if (w == texture_w && h == texture_h)
    return;
  texture_w = w;
  texture_h = h;
  scr_sync_texture ();
}

int
cmacs_screensaver_peek_frame (const void **pixels, int *w, int *h,
                              unsigned long long *generation)
{
  ScrTarget *t;
  ScrShmFrame f;
  gchar *k;

  if (!sessions[CMACS_SCREENSAVER_TEXTURE].active || targets == NULL)
    return 0;

  k = target_key (CMACS_SCREENSAVER_TEXTURE, SCR_TEXTURE_MON);
  t = g_hash_table_lookup (targets, k);
  g_free (k);

  if (t == NULL || t->map == NULL)
    return 0;
  if (!scr_shm_read_acquire (t->map, &f))
    return 0;                        /* no frame yet, or writer mid-write */

  if (pixels)     *pixels = f.pixels;
  if (w)          *w = t->w;
  if (h)          *h = t->h;
  if (generation) *generation = (unsigned long long) f.generation;
  return 1;
}

char *
cmacs_screensaver_start (int sink, const char *so_path,
                         const char *const *argv, int fps, int pause_covered)
{
  ScrSession *s;

  if (sink < 0 || sink > 1 || so_path == NULL)
    return g_strdup ("invalid screensaver sink/module");

#ifndef HAVE_CMACS_GOWL
  (void) argv; (void) fps; (void) pause_covered; (void) s;
  return g_strdup ("screensaver wallpaper/lock requires --with-cmacs-gowl");
#else
  {
    GowlCompositor *comp = cmacs_gowl_get_compositor ();
    char *serr = NULL;

    if (comp == NULL)
      return g_strdup ("gowl compositor not running (start with --gowl)");

    if (fps > 0)
      pump_fps = fps;

    /* (Re)spawn the child if needed. */
    child_proc.gave_up = FALSE;
    if (child_proc.pid == 0 && child_proc.respawn_source == 0)
      {
        char *serr2 = NULL;
        if (!scr_child_spawn (&serr2))
          return serr2 ? serr2 : g_strdup ("could not start render child");
      }

    /* Replace any existing session on this sink. */
    s = &sessions[sink];
    if (s->active)
      scr_targets_remove_sink (sink);
    g_clear_pointer (&s->so_path, g_free);
    g_clear_pointer (&s->argv, g_strfreev);
    s->active = 1;
    s->is_lock = (sink == CMACS_SCREENSAVER_LOCK) ? 1 : 0;
    s->pause_covered = pause_covered ? 1 : 0;
    s->so_path = g_strdup (so_path);
    s->argv = (argv != NULL) ? g_strdupv ((char **) argv) : NULL;

    /* Tell the child which monitors to render. */
    scr_child_send_str (scr_proto_build_set_fps (pump_fps));
    scr_sync_sink (sink, comp);

    /* Synchronous error UX: bounded wait for the first load-result. */
    serr = scr_wait_first_load (sink);
    if (serr != NULL)
      {
        cmacs_screensaver_stop (sink);
        return serr;
      }

    scr_ensure_pump ();
    return NULL;
  }
#endif
}

void
cmacs_screensaver_stop (int sink)
{
  if (sink < 0 || sink >= CMACS_SCREENSAVER_N_SINKS)
    return;
  if (!sessions[sink].active)
    return;

  scr_targets_remove_sink (sink);
  sessions[sink].active = 0;
  g_clear_pointer (&sessions[sink].so_path, g_free);
  g_clear_pointer (&sessions[sink].argv, g_strfreev);

  /* No sessions left -> stop the child (it would idle-exit anyway). */
  if (!scr_any_session_active ())
    scr_child_teardown ();
  /* The pump removes itself on the next tick when no session is active. */
}

int
cmacs_screensaver_active (int sink)
{
  if (sink < 0 || sink >= CMACS_SCREENSAVER_N_SINKS)
    return 0;
  return sessions[sink].active;
}

void
cmacs_screensaver_set_paused (int paused)
{
  child_paused = paused ? 1 : 0;
  if (child_proc.sock != NULL)
    scr_child_send_str (scr_proto_build_pause (child_paused ? TRUE : FALSE));
}

void
cmacs_screensaver_set_fps (int fps)
{
  if (fps < 1)
    fps = SCR_FPS_DEFAULT;
  if (fps > 240)
    fps = 240;
  pump_fps = fps;
  if (child_proc.sock != NULL)
    scr_child_send_str (scr_proto_build_set_fps (fps));
  scr_restart_pump ();
}

void
cmacs_screensaver_restart (void)
{
  if (!scr_any_session_active ())
    return;
  scr_child_teardown ();
  child_proc.gave_up = FALSE;
  child_proc.restart_count = 0;
  {
    char *err = NULL;
    if (scr_child_spawn (&err))
      scr_resync_all ();
    else
      {
        g_clear_pointer (&scr_last_error, g_free);
        scr_last_error = err ? err : g_strdup ("restart failed");
      }
  }
}

void
cmacs_screensaver_set_start_timeout_ms (int ms)
{
  if (ms < 100)
    ms = 100;                            /* keep the bounded wait meaningful */
  scr_start_timeout_us = (gint64) ms * 1000;
}

void
cmacs_screensaver_get_status (CmacsScreensaverStatus *out)
{
  if (out == NULL)
    return;
  memset (out, 0, sizeof *out);
  out->running = child_proc.pid != 0;
  out->pid = (long) child_proc.pid;
  out->fps = pump_fps;
  out->paused = child_paused;
  out->gave_up = child_proc.gave_up;
  out->n_targets = targets != NULL ? (int) g_hash_table_size (targets) : 0;
  out->wallpaper_active = sessions[CMACS_SCREENSAVER_WALLPAPER].active;
  out->lock_active = sessions[CMACS_SCREENSAVER_LOCK].active;
  out->last_error = scr_last_error;
}

#endif /* HAVE_CMACS_SCREENSAVER */
