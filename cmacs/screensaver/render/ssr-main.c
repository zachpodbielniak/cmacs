/* ssr-main.c --- cmacs-screensaver-render entry point.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A standalone GLib/GObject binary that Emacs spawns (one per session) to render
 * libregnum screensaver modules off-screen, in its OWN GL context, streaming
 * frames back over shared memory.  It links libregnum but NO Emacs objects, so a
 * crash here can never corrupt the editor.  The inherited control socket fd is
 * passed in CMACS_SCREENSAVER_IPC_FD. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE   /* prctl */
#endif

#include "ssr-renderer.h"

#include <glib.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <sys/prctl.h>

int
main (int argc, char **argv)
{
  const gchar *fdenv;
  int fd;
  GMainLoop *loop;
  SsrRenderer *renderer;

  (void) argc;
  (void) argv;

  fdenv = g_getenv ("CMACS_SCREENSAVER_IPC_FD");
  if (fdenv == NULL || *fdenv == '\0')
    {
      g_printerr ("cmacs-screensaver-render: CMACS_SCREENSAVER_IPC_FD unset\n");
      return 2;
    }
  fd = atoi (fdenv);
  if (fd < 0)
    {
      g_printerr ("cmacs-screensaver-render: bad ipc fd %d\n", fd);
      return 2;
    }

  /* A dead socket must never raise SIGPIPE; we detect EOF on the GSource. */
  signal (SIGPIPE, SIG_IGN);

  /* Die if Emacs dies (fires on parent death for any reason, incl. SIGKILL).
   * Re-check getppid() to close the fork/exec race where the parent already
   * exited before prctl ran. */
  prctl (PR_SET_PDEATHSIG, SIGTERM);
  if (getppid () == 1)
    return 0;

  loop = g_main_loop_new (NULL, FALSE);
  renderer = ssr_renderer_new (fd, loop);
  if (renderer == NULL)
    {
      g_main_loop_unref (loop);
      return 1;
    }

  g_main_loop_run (loop);

  g_object_unref (renderer);
  g_main_loop_unref (loop);
  return 0;
}
