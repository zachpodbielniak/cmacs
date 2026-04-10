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
#include <unistd.h>

/* ── Static state ─────────────────────────────────────────────────── */

static McpUnixSocketServer *mcp_server;
static gchar *socket_path;

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

  g_free (socket_path);
  socket_path = g_strdup_printf ("%s/cmacs-mcp-%d.sock",
                                 g_get_user_runtime_dir (),
                                 (int) getpid ());

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
    "  gowl: Wayland compositor control (clients, monitors, keybinds, spawn)\n"
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

  if (!cmacs_mcp_do_start (&error))
    g_warning ("cmacs-mcp: failed to start: %s", error->message);
  else
    g_debug ("cmacs-mcp: listening on %s", socket_path);
}

#endif /* HAVE_CMACS_MCP */
