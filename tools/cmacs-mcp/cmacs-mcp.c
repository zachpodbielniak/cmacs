/*
 * cmacs-mcp - MCP stdio-to-socket relay binary.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * This small binary bridges stdin/stdout (used by MCP clients like
 * Claude Code) to the CMacs MCP server's Unix domain socket.
 *
 * Usage:
 *   cmacs-mcp [--socket PATH | --name NAME]
 *
 * Default socket: auto-discover from $XDG_RUNTIME_DIR/cmacs-mcp-*.sock
 * Override with:  $CMACS_MCP_SOCKET or --socket flag
 *
 * Data flow:
 *   stdin  --> socket (NDJSON lines)
 *   socket --> stdout (NDJSON lines)
 */

#include <gio/gio.h>
#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>
#include <gio/gunixsocketaddress.h>
#include <glib.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static GMainLoop *main_loop = NULL;

static void
on_stdin_line (GObject      *source,
               GAsyncResult *result,
               gpointer      user_data)
{
  GDataInputStream *stream;
  GOutputStream    *sock_out;
  g_autoptr (GError) error = NULL;
  gchar            *line;
  gsize             length;
  g_autofree gchar *msg = NULL;

  stream   = G_DATA_INPUT_STREAM (source);
  sock_out = G_OUTPUT_STREAM (user_data);

  line = g_data_input_stream_read_line_finish (stream, result,
                                               &length, &error);
  if (line == NULL)
    {
      if (error != NULL)
        g_printerr ("cmacs-mcp: stdin read error: %s\n",
                     error->message);
      g_main_loop_quit (main_loop);
      return;
    }

  msg = g_strdup_printf ("%s\n", line);
  g_free (line);

  if (!g_output_stream_write_all (sock_out, msg, strlen (msg),
                                  NULL, NULL, &error))
    {
      g_printerr ("cmacs-mcp: socket write error: %s\n",
                   error->message);
      g_main_loop_quit (main_loop);
      return;
    }

  g_data_input_stream_read_line_async (stream, G_PRIORITY_DEFAULT,
                                       NULL, on_stdin_line, sock_out);
}

static void
on_socket_line (GObject      *source,
                GAsyncResult *result,
                gpointer      user_data)
{
  GDataInputStream *stream;
  g_autoptr (GError) error = NULL;
  gchar            *line;
  gsize             length;
  g_autofree gchar *msg = NULL;

  stream = G_DATA_INPUT_STREAM (source);

  line = g_data_input_stream_read_line_finish (stream, result,
                                               &length, &error);
  if (line == NULL)
    {
      if (error != NULL)
        g_printerr ("cmacs-mcp: socket read error: %s\n",
                     error->message);
      g_main_loop_quit (main_loop);
      return;
    }

  msg = g_strdup_printf ("%s\n", line);
  g_free (line);

  if (!g_output_stream_write_all (G_OUTPUT_STREAM (user_data),
                                  msg, strlen (msg), NULL, NULL,
                                  &error))
    {
      g_printerr ("cmacs-mcp: stdout write error: %s\n",
                   error->message);
      g_main_loop_quit (main_loop);
      return;
    }

  g_data_input_stream_read_line_async (stream, G_PRIORITY_DEFAULT,
                                       NULL, on_socket_line, user_data);
}

static gchar *
discover_socket (void)
{
  const gchar *runtime_dir;
  GDir        *dir;
  const gchar *entry;
  gchar       *best_path;
  time_t       best_mtime;

  runtime_dir = g_get_user_runtime_dir ();
  dir = g_dir_open (runtime_dir, 0, NULL);
  if (dir == NULL)
    return NULL;

  best_path  = NULL;
  best_mtime = 0;

  while ((entry = g_dir_read_name (dir)) != NULL)
    {
      if (g_str_has_prefix (entry, "cmacs-mcp-")
          && g_str_has_suffix (entry, ".sock"))
        {
          g_autofree gchar *full_path = NULL;
          struct stat st;

          full_path = g_build_filename (runtime_dir, entry, NULL);
          if (stat (full_path, &st) == 0 && st.st_mtime > best_mtime)
            {
              g_free (best_path);
              best_path  = g_strdup (full_path);
              best_mtime = st.st_mtime;
            }
        }
    }
  g_dir_close (dir);

  return best_path;
}

int
main (int argc, char **argv)
{
  const gchar                  *socket_path;
  g_autofree gchar             *discovered_path = NULL;
  g_autofree gchar             *named_path = NULL;
  g_autoptr (GError)            error = NULL;
  g_autoptr (GSocketClient)     client = NULL;
  g_autoptr (GSocketConnection) conn = NULL;
  g_autoptr (GSocketAddress)    address = NULL;
  GInputStream                 *sock_in;
  GOutputStream                *sock_out;
  g_autoptr (GInputStream)      stdin_stream = NULL;
  g_autoptr (GOutputStream)     stdout_stream = NULL;
  g_autoptr (GDataInputStream)  stdin_data = NULL;
  g_autoptr (GDataInputStream)  sock_data = NULL;

  /* help / license flags */
  if (argc >= 2 && (strcmp (argv[1], "-h") == 0
                    || strcmp (argv[1], "--help") == 0))
    {
      g_print (
        "Usage: cmacs-mcp [--socket PATH | --name NAME]\n\n"
        "MCP stdio-to-socket relay for CMacs (Emacs with GLib).\n\n"
        "Options:\n"
        "  --socket PATH   Unix socket path (full path)\n"
        "  --name NAME     Socket name (expands to cmacs-mcp-NAME.sock)\n"
        "  -h, --help      Show this help\n"
        "  --license       Show license information\n\n"
        "Environment:\n"
        "  CMACS_MCP_SOCKET  Override socket path (full path)\n\n"
        "Socket discovery (default):\n"
        "  If no socket/name is specified, cmacs-mcp scans\n"
        "  $XDG_RUNTIME_DIR/cmacs-mcp-*.sock and connects to the newest.\n\n"
        "Examples:\n"
        "  cmacs-mcp\n"
        "  cmacs-mcp --name myproject\n"
        "  cmacs-mcp --socket /run/user/1000/cmacs-mcp-12345.sock\n"
        "  CMACS_MCP_SOCKET=/tmp/test.sock cmacs-mcp\n");
      return 0;
    }
  if (argc >= 2 && strcmp (argv[1], "--license") == 0)
    {
      g_print (
        "cmacs-mcp - part of CMacs (Emacs with GLib/GObject)\n"
        "Copyright (C) 2026  Zach Podbielniak\n"
        "License: GNU AGPL v3 or later\n"
        "https://www.gnu.org/licenses/agpl-3.0.html\n");
      return 0;
    }

  /* determine socket path */
  socket_path = NULL;

  if (argc >= 3 && strcmp (argv[1], "--socket") == 0)
    socket_path = argv[2];
  else if (argc >= 3 && strcmp (argv[1], "--name") == 0)
    {
      named_path = g_strdup_printf ("%s/cmacs-mcp-%s.sock",
                                    g_get_user_runtime_dir (), argv[2]);
      socket_path = named_path;
    }

  if (socket_path == NULL)
    socket_path = g_getenv ("CMACS_MCP_SOCKET");

  if (socket_path == NULL)
    {
      discovered_path = discover_socket ();
      socket_path = discovered_path;
    }

  if (socket_path == NULL)
    {
      g_printerr ("cmacs-mcp: no socket found. Is CMacs running with "
                   "--with-cmacs-mcp enabled?\n"
                   "Try: cmacs-mcp --socket PATH\n");
      return 1;
    }

  /* connect to the Unix socket */
  client  = g_socket_client_new ();
  address = g_unix_socket_address_new (socket_path);

  conn = g_socket_client_connect (client,
                                  G_SOCKET_CONNECTABLE (address),
                                  NULL, &error);
  if (conn == NULL)
    {
      g_printerr ("cmacs-mcp: failed to connect to %s: %s\n",
                   socket_path, error->message);
      return 1;
    }

  /* get socket streams */
  sock_in  = g_io_stream_get_input_stream (G_IO_STREAM (conn));
  sock_out = g_io_stream_get_output_stream (G_IO_STREAM (conn));

  /* wrap stdin/stdout in GIO streams */
  stdin_stream  = g_unix_input_stream_new (0, FALSE);
  stdout_stream = g_unix_output_stream_new (1, FALSE);

  /* create data input streams for line-based reading */
  stdin_data = g_data_input_stream_new (stdin_stream);
  sock_data  = g_data_input_stream_new (sock_in);

  /* start async line readers in both directions */
  main_loop = g_main_loop_new (NULL, FALSE);

  g_data_input_stream_read_line_async (stdin_data, G_PRIORITY_DEFAULT,
                                       NULL, on_stdin_line, sock_out);
  g_data_input_stream_read_line_async (sock_data, G_PRIORITY_DEFAULT,
                                       NULL, on_socket_line,
                                       stdout_stream);

  g_main_loop_run (main_loop);

  g_main_loop_unref (main_loop);
  return 0;
}
