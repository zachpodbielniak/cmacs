/* SpaceMouse / 6DOF input for CMacs -- the connection to spacenavd.

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

spacenavd owns the device; clients read its reports from a Unix socket.
There are two ways in, and both end as one file descriptor watched by a
GSource on the CMacs GMainContext -- which Emacs pumps from its own
pselect, so a report is read and acted on in the main thread, between
commands, with no thread of ours and no polling timer:

  - libspnav (when configure found it): spnav_open / spnav_fd /
    spnav_poll_event.  It also speaks the newer protocol versions.
  - a built-in client of the original protocol, which every spacenavd
    still serves to a client that asks for nothing newer: one fixed-size
    packet per report (cmacs-spacemouse-proto.c).  It is used when
    libspnav is absent, and whenever a socket path is named -- tests run
    a fake daemon on a socket of their own.

A daemon that is not running is not an error.  With retry on, the
connection is tried again every few seconds, and after the daemon goes
away (restart, device unplugged and spacenavd stopped).  */

#include <config.h>

#ifdef HAVE_CMACS_SPACEMOUSE

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <glib.h>
#include <glib-unix.h>

#ifdef HAVE_LIBSPNAV
#include <spnav.h>
#endif

#include "cmacs-glib-loop.h"
#include "cmacs-spacemouse.h"

#define SPNAV_RETRY_SECONDS 3

static struct
{
  bool enabled;                  /* start was called, stop was not */
  bool retry;
  bool explicit_path;            /* a path was named: built-in client */
  CmacsSpnavHandler handler;
  char *path;                    /* the socket (built-in client) */
  int fd;                        /* connected descriptor, or -1 */
  bool via_libspnav;
  GSource *watch;                /* fd readable */
  GSource *retry_src;            /* reconnect timer */
  unsigned char buf[CMACS_SPNAV_PACKET_SIZE];
  size_t fill;                   /* bytes of a partial packet in BUF */
  unsigned long attempts;
} sm = { .fd = -1 };

static void spnav_disconnect (void);
static void spnav_schedule_retry (void);

/* The socket the built-in client tries: the named one, $SPNAV_SOCKET, or
   the daemon's default (/run is where /var/run points on every current
   distribution, but not always inside containers, so try both).  */
static char *
spnav_default_path (void)
{
  const char *env = g_getenv ("SPNAV_SOCKET");

  if (env != NULL && *env != '\0')
    return g_strdup (env);
  if (g_file_test ("/run/spnav.sock", G_FILE_TEST_EXISTS))
    return g_strdup ("/run/spnav.sock");
  return g_strdup ("/var/run/spnav.sock");
}

static void
spnav_deliver (const CmacsSpnavEvent *ev)
{
  if (sm.handler != NULL && ev->kind != CMACS_SPNAV_NONE)
    sm.handler (ev);
}

#ifdef HAVE_LIBSPNAV
static void
spnav_read_libspnav (void)
{
  spnav_event sev;

  while (spnav_poll_event (&sev) > 0)
    {
      CmacsSpnavEvent ev;

      memset (&ev, 0, sizeof ev);
      if (sev.type == SPNAV_EVENT_MOTION)
        {
          ev.kind = CMACS_SPNAV_MOTION;
          ev.axis[0] = sev.motion.x;
          ev.axis[1] = sev.motion.y;
          ev.axis[2] = sev.motion.z;
          ev.axis[3] = sev.motion.rx;
          ev.axis[4] = sev.motion.ry;
          ev.axis[5] = sev.motion.rz;
          ev.period_ms = sev.motion.period;
        }
      else if (sev.type == SPNAV_EVENT_BUTTON)
        {
          ev.kind = CMACS_SPNAV_BUTTON;
          ev.button = sev.button.bnum;
          ev.press = sev.button.press != 0;
        }
      else
        continue;              /* device / configuration notices */
      spnav_deliver (&ev);
    }
}
#endif

/* Read every complete packet waiting.  Returns false once the daemon has
   gone (end of file or a hard error).  */
static bool
spnav_read_socket (void)
{
  for (;;)
    {
      ssize_t n = read (sm.fd, sm.buf + sm.fill, sizeof sm.buf - sm.fill);

      if (n > 0)
        {
          sm.fill += (size_t) n;
          if (sm.fill == sizeof sm.buf)
            {
              CmacsSpnavEvent ev;

              sm.fill = 0;
              if (cmacs_spnav_decode_v0 (sm.buf, &ev))
                spnav_deliver (&ev);
            }
          continue;
        }
      if (n == 0)
        return false;
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN)
        return true;               /* drained */
#if EWOULDBLOCK != EAGAIN
      if (errno == EWOULDBLOCK)
        return true;
#endif
      return false;
    }
}

static gboolean
spnav_readable (gint fd, GIOCondition cond, gpointer data)
{
  bool alive = true;

  (void) fd;
  (void) data;
  if (cond & G_IO_IN)
    {
#ifdef HAVE_LIBSPNAV
      if (sm.via_libspnav)
        spnav_read_libspnav ();
      else
#endif
        alive = spnav_read_socket ();
    }
  if (!alive || (cond & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)))
    {
      /* The daemon went away.  Returning REMOVE destroys the source, so
         only our own reference is left to drop; the context holds one of
         its own until this dispatch returns.  */
      GSource *w = sm.watch;

      sm.watch = NULL;
      spnav_disconnect ();
      spnav_schedule_retry ();
      if (w != NULL)
        g_source_unref (w);
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

static int
spnav_connect_socket (const char *path)
{
  struct sockaddr_un addr;
  int fd;

  if (strlen (path) >= sizeof addr.sun_path)
    return -1;
  fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0)
    return -1;
  memset (&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  memcpy (addr.sun_path, path, strlen (path) + 1);
  /* Blocking connect: on a Unix socket it either completes or fails at
     once (ENOENT, ECONNREFUSED); only the reads must not block.  */
  if (connect (fd, (struct sockaddr *) &addr, sizeof addr) < 0
      || !g_unix_set_fd_nonblocking (fd, TRUE, NULL))
    {
      close (fd);
      return -1;
    }
  return fd;
}

/* One attempt.  Returns true when connected.  */
static bool
spnav_try_connect (void)
{
  GSource *src;

  if (sm.fd >= 0)
    return true;
  sm.attempts++;
  sm.fill = 0;
  sm.via_libspnav = false;

#ifdef HAVE_LIBSPNAV
  if (!sm.explicit_path)
    {
      if (spnav_open () == -1)
        return false;
      sm.fd = spnav_fd ();
      if (sm.fd < 0)
        {
          spnav_close ();
          return false;
        }
      sm.via_libspnav = true;
    }
  else
#endif
    {
      if (sm.path == NULL)
        sm.path = spnav_default_path ();
      sm.fd = spnav_connect_socket (sm.path);
      if (sm.fd < 0)
        return false;
    }

  src = g_unix_fd_source_new (sm.fd, G_IO_IN | G_IO_HUP | G_IO_ERR);
  g_source_set_callback (src, G_SOURCE_FUNC (spnav_readable), NULL, NULL);
  g_source_attach (src, cmacs_glib_get_context ());
  sm.watch = src;
  return true;
}

static void
spnav_disconnect (void)
{
  if (sm.watch != NULL)
    {
      g_source_destroy (sm.watch);
      g_source_unref (sm.watch);
      sm.watch = NULL;
    }
  if (sm.fd >= 0)
    {
#ifdef HAVE_LIBSPNAV
      if (sm.via_libspnav)
        spnav_close ();
      else
#endif
        close (sm.fd);
    }
  sm.fd = -1;
  sm.via_libspnav = false;
  sm.fill = 0;
}

static gboolean
spnav_retry_tick (gpointer data)
{
  (void) data;
  if (!sm.enabled || spnav_try_connect ())
    {
      if (sm.retry_src != NULL)
        g_source_unref (sm.retry_src);
      sm.retry_src = NULL;
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

static void
spnav_schedule_retry (void)
{
  if (!sm.enabled || !sm.retry || sm.retry_src != NULL)
    return;
  sm.retry_src = g_timeout_source_new_seconds (SPNAV_RETRY_SECONDS);
  g_source_set_callback (sm.retry_src, spnav_retry_tick, NULL, NULL);
  g_source_attach (sm.retry_src, cmacs_glib_get_context ());
}

bool
cmacs_spnav_conn_start (const char *socket_path, bool retry,
                        CmacsSpnavHandler handler)
{
  cmacs_spnav_conn_stop ();
  sm.enabled = true;
  sm.retry = retry;
  sm.handler = handler;
  sm.explicit_path = socket_path != NULL;
  sm.path = socket_path != NULL ? g_strdup (socket_path) : NULL;
  sm.attempts = 0;
  if (spnav_try_connect ())
    return true;
  spnav_schedule_retry ();
  return false;
}

void
cmacs_spnav_conn_stop (void)
{
  sm.enabled = false;
  if (sm.retry_src != NULL)
    {
      g_source_destroy (sm.retry_src);
      g_source_unref (sm.retry_src);
      sm.retry_src = NULL;
    }
  spnav_disconnect ();
  g_clear_pointer (&sm.path, g_free);
  sm.handler = NULL;
}

bool
cmacs_spnav_conn_enabled (void)
{
  return sm.enabled;
}

bool
cmacs_spnav_conn_connected (void)
{
  return sm.fd >= 0;
}

const char *
cmacs_spnav_conn_backend (void)
{
  if (sm.fd < 0)
    return NULL;
  return sm.via_libspnav ? "libspnav" : "socket";
}

const char *
cmacs_spnav_conn_socket (void)
{
  return sm.via_libspnav ? NULL : sm.path;
}

unsigned long
cmacs_spnav_conn_attempts (void)
{
  return sm.attempts;
}

#endif /* HAVE_CMACS_SPACEMOUSE */
