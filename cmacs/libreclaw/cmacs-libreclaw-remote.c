/* cmacs-libreclaw-remote.c — outbound libreclaw bridge client
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The "remote" mode for cmacs-libreclaw.  Where the embedded mode
 * runs an LcApp in-process, the remote mode instantiates an
 * LcBridgeClient that dials out to a separately running libreclaw
 * server's /api/v1/bridge WebSocket and tunnels cmacs's MCP server
 * back across so the remote agent can drive the editor.
 *
 * The actual chat-room buffer machinery is the same as the embedded
 * mode — every chat.message_in frame is dispatched into the existing
 * `cmacs-libreclaw--on-message' Elisp handler with a synthesised
 * channel-id of `bridge:<host>'.  Org-mode buffer creation, history
 * tracking and reply round-trip therefore Just Work without
 * additional Elisp plumbing. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <lc-version.h>
#include <mcp.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"
#ifdef HAVE_CMACS_MCP
#include "cmacs-mcp.h"
#include "cmacs-mcp-tools.h"
#endif

#include <glib.h>

/* ── State ─────────────────────────────────────────────────────────── */

static LcBridgeClient *cmacs_bridge_client = NULL;
static McpServer      *cmacs_bridge_self_server = NULL;
static gulong          sig_chat_msg_id     = 0;
static gulong          sig_chat_room_add   = 0;
static gulong          sig_chat_room_rm    = 0;
static gulong          sig_connected_id    = 0;
static gulong          sig_disconnected_id = 0;
static gulong          sig_error_id        = 0;

/* Forward declarations for the DEFUNs below.  These match the
 * EXFUN entries make-docfile will generate into src/globals.h on
 * the next build; declaring them locally lets the DEFUN macro's
 * static struct initializer reference them before make-docfile
 * has been re-run. */
extern Lisp_Object
Fcmacs_libreclaw_remote__connect_internal (Lisp_Object url,
                                            Lisp_Object token,
                                            Lisp_Object display_name,
                                            Lisp_Object endpoints,
                                            Lisp_Object user_id);
extern Lisp_Object
Fcmacs_libreclaw_remote_disconnect (void);
extern Lisp_Object
Fcmacs_libreclaw_remote_connected_p (void);
extern Lisp_Object
Fcmacs_libreclaw_remote_send_message (Lisp_Object room_id,
                                       Lisp_Object body,
                                       Lisp_Object html_body);

/* DEFSYM-backed Q* symbols are defined in syms_of_cmacs_libreclaw_remote
 * below.  make-docfile scans those DEFSYM lines and emits the matching
 * Q* macros into src/globals.h, so no local declarations are needed. */

/* ── Signal forwarders ─────────────────────────────────────────────── */

static void
forward_to_lisp_1str (Lisp_Object sym, const char *s1)
{
  Lisp_Object a1 = (s1 != NULL) ? build_string (s1) : Qnil;
  cmacs_libreclaw_dispatch_to_lisp (sym, a1, Qnil, Qnil, Qnil, Qnil);
}

static void
forward_to_lisp_0 (Lisp_Object sym)
{
  cmacs_libreclaw_dispatch_to_lisp (sym, Qnil, Qnil, Qnil, Qnil, Qnil);
}

/* Quote a C string as a Lisp string literal for splicing into an
 * eval expression.  Mirrors the static helper in cmacs-libreclaw.c
 * — re-implemented here because it isn't exported.  NULL → "nil". */
static gchar *
remote_quote_lisp_string (const char *s)
{
  GString *out;
  const char *p;

  if (s == NULL)
    return g_strdup ("nil");
  out = g_string_new ("\"");
  for (p = s; *p != '\0'; p++)
    {
      if (*p == '"' || *p == '\\')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  g_string_append_c (out, '"');
  return g_string_free (out, FALSE);
}

static void
on_chat_message_received (LcBridgeClient   *client,
                          LcInboundMessage *msg,
                          gpointer          user_data)
{
  const char *room_id;
  const char *sender_id;
  const char *sender_name;
  const char *body;
  gint64      timestamp;
  g_autofree gchar *q_room   = NULL;
  g_autofree gchar *q_sender = NULL;
  g_autofree gchar *q_sname  = NULL;
  g_autofree gchar *q_body   = NULL;
  g_autofree gchar *expr     = NULL;

  (void) client;
  (void) user_data;

  if (msg == NULL)
    return;

  room_id     = lc_inbound_message_get_room_id    (msg);
  sender_id   = lc_inbound_message_get_sender_id  (msg);
  sender_name = lc_inbound_message_get_sender_name(msg);
  body        = lc_inbound_message_get_body       (msg);
  timestamp   = lc_inbound_message_get_timestamp  (msg);

  /* The shared 5-arg dispatcher can't carry sender_name + integer
   * timestamp, so build the call expression ourselves and hand it
   * to cmacs_libreclaw_dispatch_expr (same dispatch path, just a
   * different call shape). */
  q_room   = remote_quote_lisp_string (room_id);
  q_sender = remote_quote_lisp_string (sender_id);
  q_sname  = remote_quote_lisp_string (sender_name);
  q_body   = remote_quote_lisp_string (body);

  expr = g_strdup_printf (
      "(cmacs-libreclaw-remote--on-chat-message \"bridge\" %s %s %s %s %"
      G_GINT64_FORMAT ")",
      q_room, q_sender, q_sname, q_body, timestamp);

  cmacs_libreclaw_dispatch_expr (expr);
}

static void
on_chat_room_added (LcBridgeClient *client,
                    const gchar    *room_id,
                    gpointer        user_data)
{
  (void) client;
  (void) user_data;
  forward_to_lisp_1str (Qcmacs_libreclaw_remote_on_room_added, room_id);
}

static void
on_chat_room_removed (LcBridgeClient *client,
                      const gchar    *room_id,
                      gpointer        user_data)
{
  (void) client;
  (void) user_data;
  forward_to_lisp_1str (Qcmacs_libreclaw_remote_on_room_removed, room_id);
}

static void
on_connected (LcBridgeClient *client, gpointer user_data)
{
  (void) client;
  (void) user_data;
  forward_to_lisp_0 (Qcmacs_libreclaw_remote_on_connected);
}

static void
on_disconnected (LcBridgeClient *client, gpointer user_data)
{
  (void) client;
  (void) user_data;
  forward_to_lisp_0 (Qcmacs_libreclaw_remote_on_disconnected);
}

static void
on_bridge_error (LcBridgeClient *client, GError *error, gpointer user_data)
{
  (void) client;
  (void) user_data;
  forward_to_lisp_1str (Qcmacs_libreclaw_remote_on_error,
                        error ? error->message : "(unknown)");
}

/* ── McpServer factory for the :self endpoint ──────────────────────── */

#ifdef HAVE_CMACS_MCP
static McpServer *
build_self_mcp_server (void)
{
  McpServer *server;

  server = mcp_server_new ("cmacs-mcp-bridge", PACKAGE_VERSION);
  /* Register the same tools / resources / prompts the local
   * cmacs-mcp Unix socket exposes.  These DEFUN-backed handlers all
   * run inline on the cmacs main thread, which is also the main
   * thread the bridge transport delivers frames on. */
  cmacs_mcp_register_all_tools (server);
  cmacs_mcp_register_resources (server);
  cmacs_mcp_register_prompts   (server);
  return server;
}
#endif

/* ── DEFUNs ────────────────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-remote--connect-internal",
       Fcmacs_libreclaw_remote__connect_internal,
       Scmacs_libreclaw_remote__connect_internal, 2, 5, 0,
       doc: /* Internal: open the bridge to URL with bearer TOKEN.
Optional DISPLAY-NAME identifies this client to the remote server.
Optional ENDPOINTS is a list of endpoint specs (currently only the
symbol `cmacs' is supported, which exposes cmacs's own MCP tools).
The default endpoint list is `(cmacs)'.
Optional USER-ID is the sender_id stamped on every outbound chat
frame — match it against the libreclaw server's
`session.command_allowed_users' / `messages.command_allowed_users'
to enable `!session'-class commands on the bridge channel.  When
nil, the server falls back to the bridge id (unstable across
reconnects).
Returns t on dispatch.  */)
  (Lisp_Object url, Lisp_Object token,
   Lisp_Object display_name, Lisp_Object endpoints,
   Lisp_Object user_id)
{
  GMainContext *ctx;

  CHECK_STRING (url);
  CHECK_STRING (token);

  if (cmacs_bridge_client != NULL
      && lc_bridge_client_is_connected (cmacs_bridge_client))
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("remote bridge already connected"));

  /* Stale client (created but never connected, or cleanly
   * disconnected without Fdisconnect): drop it so we can
   * create a fresh one below. */
  if (cmacs_bridge_client != NULL)
    g_clear_object (&cmacs_bridge_client);

  /* The bridge dispatches inbound MCP frames onto its main context;
   * use cmacs's GLib context (the one the GLib loop hook pumps)
   * so signal handlers always run on the main thread. */
  ctx = g_main_context_default ();
  cmacs_bridge_client = lc_bridge_client_new (ctx);

  lc_bridge_client_set_url          (cmacs_bridge_client, SSDATA (url));
  lc_bridge_client_set_bearer_token (cmacs_bridge_client, SSDATA (token));
  if (!NILP (display_name))
    {
      CHECK_STRING (display_name);
      lc_bridge_client_set_display_name (cmacs_bridge_client,
                                         SSDATA (display_name));
    }
  if (!NILP (user_id))
    {
      CHECK_STRING (user_id);
      lc_bridge_client_set_local_user_id (cmacs_bridge_client,
                                           SSDATA (user_id));
    }

  /* Endpoint roster.  Default (or any list containing `cmacs') wires
   * up the local cmacs MCP tool surface as endpoint id "cmacs". */
  {
    bool want_self = NILP (endpoints);    /* default: just cmacs */
    Lisp_Object tail = endpoints;

    while (!NILP (tail) && CONSP (tail))
      {
        Lisp_Object spec = XCAR (tail);
        if (SYMBOLP (spec) && EQ (spec, intern ("cmacs")))
          want_self = true;
        /* Other spec kinds (:stdio, :unix-socket, :ws) reserved
         * for future versions; silently ignored for now. */
        tail = XCDR (tail);
      }

    if (want_self)
      {
#ifdef HAVE_CMACS_MCP
        cmacs_bridge_self_server = build_self_mcp_server ();
        lc_bridge_client_add_mcp_endpoint (cmacs_bridge_client,
                                           "cmacs", "cmacs editor",
                                           cmacs_bridge_self_server);
#else
        xsignal1 (Qcmacs_libreclaw_error,
                  build_string ("cmacs was built without --with-cmacs-mcp; "
                                "cannot export :self endpoint"));
#endif
      }
  }

  sig_chat_msg_id = g_signal_connect (cmacs_bridge_client,
                                       "chat-message-received",
                                       G_CALLBACK (on_chat_message_received),
                                       NULL);
  sig_chat_room_add = g_signal_connect (cmacs_bridge_client,
                                         "chat-room-added",
                                         G_CALLBACK (on_chat_room_added),
                                         NULL);
  sig_chat_room_rm  = g_signal_connect (cmacs_bridge_client,
                                         "chat-room-removed",
                                         G_CALLBACK (on_chat_room_removed),
                                         NULL);
  sig_connected_id  = g_signal_connect (cmacs_bridge_client,
                                         "connected",
                                         G_CALLBACK (on_connected),
                                         NULL);
  sig_disconnected_id = g_signal_connect (cmacs_bridge_client,
                                           "disconnected",
                                           G_CALLBACK (on_disconnected),
                                           NULL);
  sig_error_id = g_signal_connect (cmacs_bridge_client,
                                    "error",
                                    G_CALLBACK (on_bridge_error),
                                    NULL);

  lc_bridge_client_connect_async (cmacs_bridge_client, NULL, NULL, NULL);
  return Qt;
}

DEFUN ("cmacs-libreclaw-remote-disconnect",
       Fcmacs_libreclaw_remote_disconnect,
       Scmacs_libreclaw_remote_disconnect, 0, 0, 0,
       doc: /* Disconnect the remote bridge, if any.  Safe to call
twice.  Returns t when something was disconnected, nil otherwise.  */)
  (void)
{
  if (cmacs_bridge_client == NULL)
    return Qnil;

  if (sig_chat_msg_id != 0)
    g_signal_handler_disconnect (cmacs_bridge_client, sig_chat_msg_id);
  if (sig_chat_room_add != 0)
    g_signal_handler_disconnect (cmacs_bridge_client, sig_chat_room_add);
  if (sig_chat_room_rm != 0)
    g_signal_handler_disconnect (cmacs_bridge_client, sig_chat_room_rm);
  if (sig_connected_id != 0)
    g_signal_handler_disconnect (cmacs_bridge_client, sig_connected_id);
  if (sig_disconnected_id != 0)
    g_signal_handler_disconnect (cmacs_bridge_client, sig_disconnected_id);
  if (sig_error_id != 0)
    g_signal_handler_disconnect (cmacs_bridge_client, sig_error_id);
  sig_chat_msg_id = sig_chat_room_add = sig_chat_room_rm = 0;
  sig_connected_id = sig_disconnected_id = sig_error_id = 0;

  lc_bridge_client_disconnect_async (cmacs_bridge_client, NULL, NULL, NULL);
  g_clear_object (&cmacs_bridge_client);
  g_clear_object (&cmacs_bridge_self_server);
  return Qt;
}

DEFUN ("cmacs-libreclaw-remote-connected-p",
       Fcmacs_libreclaw_remote_connected_p,
       Scmacs_libreclaw_remote_connected_p, 0, 0, 0,
       doc: /* Return non-nil if the remote bridge is connected.  */)
  (void)
{
  if (cmacs_bridge_client == NULL)
    return Qnil;
  return lc_bridge_client_is_connected (cmacs_bridge_client) ? Qt : Qnil;
}

DEFUN ("cmacs-libreclaw-remote-send-message",
       Fcmacs_libreclaw_remote_send_message,
       Scmacs_libreclaw_remote_send_message, 2, 3, 0,
       doc: /* Send BODY to ROOM-ID over the remote bridge.
Optional HTML-BODY supplies HTML formatting.  Returns t on success,
signals `cmacs-libreclaw-error' on failure.  */)
  (Lisp_Object room_id, Lisp_Object body, Lisp_Object html_body)
{
  LcOutboundMessage *msg;
  GError *error = NULL;
  const char *html = NULL;

  CHECK_STRING (room_id);
  CHECK_STRING (body);
  if (!NILP (html_body))
    {
      CHECK_STRING (html_body);
      html = SSDATA (html_body);
    }
  if (cmacs_bridge_client == NULL
      || !lc_bridge_client_is_connected (cmacs_bridge_client))
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("remote bridge not connected"));

  msg = lc_outbound_message_new ("bridge", SSDATA (room_id), NULL,
                                  SSDATA (body), html, NULL);
  if (!lc_bridge_client_send_message (cmacs_bridge_client, msg, &error))
    {
      Lisp_Object emsg = build_string (error ? error->message : "send failed");
      lc_outbound_message_free (msg);
      if (error) g_error_free (error);
      xsignal1 (Qcmacs_libreclaw_error, emsg);
    }
  lc_outbound_message_free (msg);
  return Qt;
}

/* ── Init ──────────────────────────────────────────────────────────── */

void
syms_of_cmacs_libreclaw_remote (void)
{
  DEFSYM (Qcmacs_libreclaw_remote_on_chat_message,
          "cmacs-libreclaw-remote--on-chat-message");
  DEFSYM (Qcmacs_libreclaw_remote_on_room_added,
          "cmacs-libreclaw-remote--on-room-added");
  DEFSYM (Qcmacs_libreclaw_remote_on_room_removed,
          "cmacs-libreclaw-remote--on-room-removed");
  DEFSYM (Qcmacs_libreclaw_remote_on_connected,
          "cmacs-libreclaw-remote--on-connected");
  DEFSYM (Qcmacs_libreclaw_remote_on_disconnected,
          "cmacs-libreclaw-remote--on-disconnected");
  DEFSYM (Qcmacs_libreclaw_remote_on_error,
          "cmacs-libreclaw-remote--on-error");

  defsubr (&Scmacs_libreclaw_remote__connect_internal);
  defsubr (&Scmacs_libreclaw_remote_disconnect);
  defsubr (&Scmacs_libreclaw_remote_connected_p);
  defsubr (&Scmacs_libreclaw_remote_send_message);
}

#endif /* HAVE_CMACS_LIBRECLAW */
