/*
 * cmacs-mcp.c — CMacs MCP server subsystem
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds an McpUnixSocketServer on the CMacs GMainContext so AI agents
 * can introspect and control the entire Emacs runtime.  The server
 * listens on $XDG_RUNTIME_DIR/cmacs-mcp-<PID>.sock and handles
 * multiple concurrent client sessions.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-glib-loop.h"

#include <mcp.h>
#include <errno.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── Static state ─────────────────────────────────────────────────── */

static McpUnixSocketServer *mcp_server;
static gchar               *socket_path;
static McpServer           *cmacs_mcp_internal_server;

/* ── Session lifecycle ────────────────────────────────────────────── */

static void
on_session_created (McpUnixSocketServer *unix_server,
                    McpServer           *server,
                    gpointer             user_data)
{
  (void) unix_server;
  (void) user_data;

  cmacs_mcp_register_all_tools (server);
  cmacs_mcp_register_resources (server);
  cmacs_mcp_register_prompts (server);
}

/* ── Public API ───────────────────────────────────────────────────── */

McpUnixSocketServer *
cmacs_mcp_get_server (void)
{
  return mcp_server;
}

const gchar *
cmacs_mcp_get_socket_path (void)
{
  return socket_path;
}

McpServer *
cmacs_mcp_get_internal_server (void)
{
  /* Lazy init: `init_cmacs_mcp' only runs in interactive mode (the
   * Unix-socket server isn't useful in --batch), but in-process
   * consumers like the cmacs-ai MCP bridge need the tool registry
   * regardless.  First call here populates it. */
  if (cmacs_mcp_internal_server == NULL)
    {
      cmacs_mcp_internal_server = mcp_server_new ("cmacs-mcp-internal",
                                                  "0.1.0");
      cmacs_mcp_register_all_tools (cmacs_mcp_internal_server);
      cmacs_mcp_register_resources (cmacs_mcp_internal_server);
      cmacs_mcp_register_prompts (cmacs_mcp_internal_server);
    }
  return cmacs_mcp_internal_server;
}

/* ── Socket file lifecycle ────────────────────────────────────────────
 *
 * The listening socket is a real file in $XDG_RUNTIME_DIR, and nothing
 * removed it: stopping the server closed the listener and left the inode
 * behind, so a machine accumulated one dead cmacs-mcp-<pid>.sock per
 * session ever run.  Three ways they are cleaned up, because there are
 * three ways they are left:
 *
 *   - a clean stop unlinks its own (cmacs_mcp_do_stop);
 *   - exiting without stopping is covered by an atexit handler, which
 *     `kill-emacs' reaches because it calls exit();
 *   - a crash or SIGKILL reaches neither, so a start sweeps the
 *     directory for sockets whose owning process is gone.
 *
 * The sweep is what actually clears a machine that has been accumulating
 * them; the other two stop it happening again. */

static void
cmacs_mcp_unlink_socket (void)
{
  if (socket_path == NULL)
    return;
  if (g_unlink (socket_path) != 0 && errno != ENOENT)
    g_debug ("cmacs-mcp: could not remove %s: %s",
             socket_path, g_strerror (errno));
}

static void
cmacs_mcp_atexit (void)
{
  /* Only the file.  Tearing the server down here would run GObject
   * finalisers at exit, and this may be reached from an unusual state. */
  cmacs_mcp_unlink_socket ();
}

/* True when PID names a process that is still around.  Signal 0 does no
 * signalling, only the permission-and-existence check; EPERM means it
 * exists and is not ours, which still counts as live. */
static gboolean
cmacs_mcp_pid_alive (long pid)
{
  if (pid <= 0)
    return TRUE;                /* unparseable: leave it alone */
  if (kill ((pid_t) pid, 0) == 0)
    return TRUE;
  return errno != ESRCH;
}

/* Remove cmacs-mcp-<pid>.sock files whose process is gone.  Bounded to
 * this user's runtime directory, and never touches a live one -- another
 * running cmacs is a normal thing to find here. */
static void
cmacs_mcp_sweep_stale_sockets (void)
{
  const gchar *dirname = g_get_user_runtime_dir ();
  g_autoptr (GDir) dir = NULL;
  const gchar *name;

  if (dirname == NULL)
    return;
  dir = g_dir_open (dirname, 0, NULL);
  if (dir == NULL)
    return;

  while ((name = g_dir_read_name (dir)) != NULL)
    {
      const gchar *digits;
      gchar *end = NULL;
      long pid;
      g_autofree gchar *path = NULL;

      if (!g_str_has_prefix (name, "cmacs-mcp-")
          || !g_str_has_suffix (name, ".sock"))
        continue;

      digits = name + strlen ("cmacs-mcp-");
      pid = strtol (digits, &end, 10);
      /* Only the exact cmacs-mcp-<digits>.sock shape, so a file that
       * merely looks similar is never removed. */
      if (end == digits || g_strcmp0 (end, ".sock") != 0)
        continue;
      if (cmacs_mcp_pid_alive (pid))
        continue;

      path = g_build_filename (dirname, name, NULL);
      if (g_unlink (path) == 0)
        g_debug ("cmacs-mcp: removed stale socket %s", path);
    }
}

/* ── Start / stop helpers ─────────────────────────────────────────── */

static gboolean
cmacs_mcp_do_start (GError **error)
{
  GMainContext *ctx;

  if (mcp_server != NULL)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "MCP server already running");
      return FALSE;
    }

  /* Clear out sockets left by sessions that never got to remove their
   * own, before claiming ours. */
  cmacs_mcp_sweep_stale_sockets ();

  g_free (socket_path);
  socket_path = g_strdup_printf ("%s/cmacs-mcp-%d.sock",
                                 g_get_user_runtime_dir (),
                                 (int) getpid ());

  /* Our own path may still exist if a previous process held this pid and
   * died badly; binding onto a leftover inode fails. */
  cmacs_mcp_unlink_socket ();

  /* Registered once, and only when a server is actually started, so a
   * session that never runs one adds no exit work. */
  {
    static gboolean atexit_registered = FALSE;
    if (!atexit_registered)
      {
        atexit (cmacs_mcp_atexit);
        atexit_registered = TRUE;
      }
  }

  mcp_server = mcp_unix_socket_server_new ("cmacs-mcp",
                                            PACKAGE_VERSION,
                                            socket_path);

  mcp_unix_socket_server_set_instructions (mcp_server,
    "CMacs MCP server — full Emacs runtime access.\n"
    "\n"
    "Available tool categories:\n"
    "  eval: evaluate Elisp, describe functions/variables, apropos, completions\n"
    "  buffer: list, read, write, create, kill, switch, save buffers; find-file\n"
    "  window: list windows/frames, split, delete, select windows\n"
    "  input: send key sequences, execute interactive commands\n"
    "  process: list subprocesses, send input to process buffers\n"
    "  debug: backtrace, memory info, messages, modes, hooks, profiler\n"
#ifdef HAVE_CMACS_GI
    "  gi: call GObject Introspection functions, list namespaces, describe types\n"
#endif
#ifdef HAVE_CMACS_GOWL
    "  gowl: Wayland compositor control (clients, monitors, keybinds, spawn),\n"
    "        and bounded recording of real input (off by default)\n"
#endif
    "\n"
    "The 'eval' tool is the universal gateway — any Elisp expression can be\n"
    "evaluated, giving access to all Emacs functionality including all cmacs\n"
    "subsystems (gowl, podomation, bacon, crispy, gi).\n"
    "\n"
    "Resources: buffer://{name}, file://{path}, messages://, variable://{name}\n"
    "Prompts: debug_session, code_review\n");

  g_signal_connect (mcp_server, "session-created",
                    G_CALLBACK (on_session_created), NULL);

  /* Attach the GSocketService to the CMacs GMainContext. */
  ctx = cmacs_glib_get_context ();
  g_main_context_push_thread_default (ctx);
  if (!mcp_unix_socket_server_start (mcp_server, error))
    {
      g_main_context_pop_thread_default (ctx);
      g_clear_object (&mcp_server);
      return FALSE;
    }
  g_main_context_pop_thread_default (ctx);

  return TRUE;
}

static void
cmacs_mcp_do_stop (void)
{
  if (mcp_server == NULL)
    return;

  mcp_unix_socket_server_stop (mcp_server);
  g_clear_object (&mcp_server);
  /* After the listener is closed, so nothing can connect to a path that
   * is no longer being served. */
  cmacs_mcp_unlink_socket ();
}

/* ── DEFUNs ───────────────────────────────────────────────────────── */

DEFUN ("cmacs-mcp-server-p", Fcmacs_mcp_server_p,
       Scmacs_mcp_server_p, 0, 0, 0,
       doc: /* Return non-nil if the CMacs MCP server is running. */)
  (void)
{
  if (mcp_server != NULL
      && mcp_unix_socket_server_is_running (mcp_server))
    return Qt;
  return Qnil;
}

DEFUN ("cmacs-mcp-socket-path", Fcmacs_mcp_socket_path,
       Scmacs_mcp_socket_path, 0, 0, 0,
       doc: /* Return the Unix socket path of the CMacs MCP server.
Returns nil if the server is not running. */)
  (void)
{
  if (socket_path == NULL)
    return Qnil;
  return build_string (socket_path);
}

DEFUN ("cmacs-mcp-session-count", Fcmacs_mcp_session_count,
       Scmacs_mcp_session_count, 0, 0, 0,
       doc: /* Return the number of active MCP client sessions. */)
  (void)
{
  if (mcp_server == NULL)
    return make_fixnum (0);
  return make_fixnum (mcp_unix_socket_server_get_session_count (mcp_server));
}

DEFUN ("cmacs-mcp-start", Fcmacs_mcp_start,
       Scmacs_mcp_start, 0, 0, 0,
       doc: /* Start the CMacs MCP server.
The server listens on a Unix domain socket at
$XDG_RUNTIME_DIR/cmacs-mcp-PID.sock.
Signals an error if the server is already running. */)
  (void)
{
  g_autoptr (GError) error = NULL;
  if (!cmacs_mcp_do_start (&error))
    xsignal1 (intern ("error"), build_string (error->message));
  return Qt;
}

DEFUN ("cmacs-mcp-stop", Fcmacs_mcp_stop,
       Scmacs_mcp_stop, 0, 0, 0,
       doc: /* Stop the CMacs MCP server and disconnect all clients. */)
  (void)
{
  cmacs_mcp_do_stop ();
  return Qnil;
}

/* ── Subsystem registration ──────────────────────────────────────── */

void
syms_of_cmacs_mcp (void)
{
  defsubr (&Scmacs_mcp_server_p);
  defsubr (&Scmacs_mcp_socket_path);
  defsubr (&Scmacs_mcp_session_count);
  defsubr (&Scmacs_mcp_start);
  defsubr (&Scmacs_mcp_stop);
}

void
init_cmacs_mcp (void)
{
  g_autoptr (GError) error = NULL;

  /* Eagerly populate the in-process tool registry (see
   * `cmacs_mcp_get_internal_server' for full notes).  This is
   * cheap and ensures bacon `cmacsgi' + the cmacs-ai MCP bridge
   * see a ready server immediately without an init-order race. */
  (void) cmacs_mcp_get_internal_server ();

  if (!cmacs_mcp_do_start (&error))
    g_warning ("cmacs-mcp: failed to start: %s", error->message);
  else
    g_debug ("cmacs-mcp: listening on %s", socket_path);
}

#endif /* HAVE_CMACS_MCP */
