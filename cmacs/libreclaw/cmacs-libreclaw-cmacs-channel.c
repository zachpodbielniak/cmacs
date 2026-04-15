/* cmacs-libreclaw-cmacs-channel.c — Cmacs-native channel integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DEFUNs for driving libreclaw's LcCmacsChannel from Elisp.  The
 * channel itself is implemented in
 * deps/libreclaw/src/channel/lc-cmacs-channel.c — an in-process
 * LcChannel that lets the Emacs host push inbound messages into
 * libreclaw's pipeline and receive AI responses via a callback.
 *
 * This file provides:
 *
 *   - cmacs-libreclaw-cmacs-channel-bind     (called from start)
 *   - cmacs-libreclaw-cmacs-channel-unbind   (called from stop)
 *   - cmacs-libreclaw-cmacs-channel-inject   (user-facing DEFUN)
 *   - cmacs-libreclaw-cmacs-channel-register-room
 *   - cmacs-libreclaw-cmacs-channel-list-rooms
 *   - a C-side response callback that formats a Lisp call and
 *     dispatches it through cmacs_libreclaw_dispatch_expr so the
 *     Elisp layer can render the message into the right buffer.
 *
 * The cmacs-side tracks a single global LcCmacsChannel* pointer.
 * It is resolved by name ("cmacs") from the channel manager after
 * libreclaw starts in cmacs_libreclaw_cmacs_channel_bind(). */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <glib.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"

/* ── State ──────────────────────────────────────────────────────── */

static LcCmacsChannel *cmacs_libreclaw_cmacs_channel = NULL;

/* ── Helpers ────────────────────────────────────────────────────── */

/* Return the cmacs channel or NULL.  DEFUNs use this to gate
 * operations when the subsystem isn't running. */
static LcCmacsChannel *
get_cmacs_channel (void)
{
  return cmacs_libreclaw_cmacs_channel;
}

/* Produce a Lisp-string literal for a possibly-NULL C string,
 * escaping embedded quotes/backslashes.  Duplicates qstr() from
 * cmacs-libreclaw-room.c — kept local so the two files stay
 * independently buildable. */
static gchar *
cmacs_qstr (const char *s)
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

/* ── Response callback ─────────────────────────────────────────── */

/*
 * Called on the main thread (via cmacs's GMainContext) whenever
 * libreclaw has an outbound message to deliver through the cmacs
 * channel.  We format a (cmacs-libreclaw--on-cmacs-response
 * "channel-id" "room-id" "sender" "body") call and dispatch it
 * via cmacs_libreclaw_dispatch_expr — the same guard path
 * cmacs-libreclaw-room.c uses for inbound-message events.
 *
 * The target_room on the outbound is the room the Emacs host
 * originally injected against, so the dispatch hits the correct
 * buffer in cmacs-libreclaw-rooms-alist.
 */
static void
cmacs_libreclaw_cmacs_response_cb (LcCmacsChannel          *channel,
                                   const LcOutboundMessage *msg,
                                   gpointer                 user_data)
{
  g_autofree gchar *chan_q = NULL;
  g_autofree gchar *room_q = NULL;
  g_autofree gchar *body_q = NULL;
  g_autofree gchar *html_q = NULL;
  g_autofree gchar *thread_q = NULL;
  g_autofree gchar *expr = NULL;

  (void) channel;
  (void) user_data;

  if (msg == NULL)
    return;

  chan_q   = cmacs_qstr (lc_outbound_message_get_channel_id (msg));
  room_q   = cmacs_qstr (lc_outbound_message_get_target_room (msg));
  body_q   = cmacs_qstr (lc_outbound_message_get_body (msg));
  html_q   = cmacs_qstr (lc_outbound_message_get_html_body (msg));
  thread_q = cmacs_qstr (lc_outbound_message_get_thread_id (msg));

  expr = g_strdup_printf (
      "(cmacs-libreclaw--on-cmacs-response %s %s %s %s %s)",
      chan_q, room_q, body_q, html_q, thread_q);

  cmacs_libreclaw_dispatch_expr (expr);
}

/* ── Bind / unbind ─────────────────────────────────────────────── */

/*
 * Look up the "cmacs" channel in the running LcApp's channel
 * manager and install our response callback.  Called from
 * cmacs-libreclaw.c at the end of the start path, AFTER
 * lc_app_start_embedded() has registered all channels from config.
 * Safe to call multiple times — only the most recent callback
 * registration wins, and we idempotently look up the pointer.
 */
void
cmacs_libreclaw_cmacs_channel_bind (LcApp *app)
{
  LcChannelManager *mgr;
  GList *channels;
  GList *l;
  LcCmacsChannel *found = NULL;

  if (app == NULL)
    return;

  mgr = lc_app_get_channel_manager (app);
  if (mgr == NULL)
    return;

  channels = lc_channel_manager_list_channels (mgr);
  for (l = channels; l != NULL; l = l->next)
    {
      LcChannel *ch = l->data;
      if (LC_IS_CMACS_CHANNEL (ch))
        {
          found = LC_CMACS_CHANNEL (ch);
          break;
        }
    }
  g_list_free (channels);

  cmacs_libreclaw_cmacs_channel = found;

  if (found != NULL)
    {
      lc_cmacs_channel_set_response_callback (
          found, cmacs_libreclaw_cmacs_response_cb, NULL, NULL);
      g_info ("cmacs-libreclaw: cmacs channel bound "
              "(response callback registered)");
    }
  else
    {
      g_info ("cmacs-libreclaw: no cmacs channel in config — "
              "inject/open DEFUNs will signal an error");
    }
}

/*
 * Drop the cmacs channel pointer and clear its response callback.
 * Called from cmacs-libreclaw.c on stop, BEFORE lc_app_stop_embedded
 * so the channel itself is still valid while we detach from it.
 */
void
cmacs_libreclaw_cmacs_channel_unbind (void)
{
  if (cmacs_libreclaw_cmacs_channel != NULL)
    {
      lc_cmacs_channel_set_response_callback (
          cmacs_libreclaw_cmacs_channel, NULL, NULL, NULL);
      cmacs_libreclaw_cmacs_channel = NULL;
    }
}

/* ── DEFUNs ────────────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-cmacs-channel-available-p",
       Fcmacs_libreclaw_cmacs_channel_available_p,
       Scmacs_libreclaw_cmacs_channel_available_p, 0, 0, 0,
       doc: /* Return non-nil if the cmacs channel is bound.
Requires both (cmacs-libreclaw-running-p) and a `channels: cmacs:
enabled: true' block in the YAML config that was loaded.  */)
  (void)
{
  return get_cmacs_channel () != NULL ? Qt : Qnil;
}

DEFUN ("cmacs-libreclaw-cmacs-channel-inject",
       Fcmacs_libreclaw_cmacs_channel_inject,
       Scmacs_libreclaw_cmacs_channel_inject, 3, 4, 0,
       doc: /* Inject BODY as an inbound message on ROOM-ID from SENDER-ID.
Optional SENDER-NAME for the human-readable display name.

This pushes the message into libreclaw's inbound pipeline as if it
had arrived over an external protocol, so it's routed through
`LcChannelManager', `LcRouter', and `LcSessionManager' to the AI
provider.  The AI response eventually flows back through the
registered response callback and lands in the matching Emacs
buffer via `cmacs-libreclaw--on-cmacs-response'.

Signals `cmacs-libreclaw-error' if the cmacs channel is not bound.  */)
  (Lisp_Object room_id, Lisp_Object sender_id, Lisp_Object body,
   Lisp_Object sender_name)
{
  LcCmacsChannel *ch;
  const char *name;

  CHECK_STRING (room_id);
  CHECK_STRING (sender_id);
  CHECK_STRING (body);

  ch = get_cmacs_channel ();
  if (ch == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("cmacs channel not bound; "
                            "check (channels.cmacs.enabled: true) in YAML"));

  name = NILP (sender_name) ? NULL : (CHECK_STRING (sender_name),
                                       SSDATA (sender_name));

  lc_cmacs_channel_inject_message (ch,
                                   SSDATA (room_id),
                                   SSDATA (sender_id),
                                   name,
                                   SSDATA (body),
                                   NULL);
  return Qt;
}

DEFUN ("cmacs-libreclaw-cmacs-channel-register-room",
       Fcmacs_libreclaw_cmacs_channel_register_room,
       Scmacs_libreclaw_cmacs_channel_register_room, 1, 1, 0,
       doc: /* Mark ROOM-ID as a known room on the cmacs channel.
Idempotent — safe to call multiple times.  Signals
`cmacs-libreclaw-error' if the cmacs channel is not bound.  */)
  (Lisp_Object room_id)
{
  LcCmacsChannel *ch;

  CHECK_STRING (room_id);
  ch = get_cmacs_channel ();
  if (ch == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("cmacs channel not bound"));
  lc_cmacs_channel_register_room (ch, SSDATA (room_id));
  return Qt;
}

DEFUN ("cmacs-libreclaw-cmacs-channel-unregister-room",
       Fcmacs_libreclaw_cmacs_channel_unregister_room,
       Scmacs_libreclaw_cmacs_channel_unregister_room, 1, 1, 0,
       doc: /* Remove ROOM-ID from the cmacs channel's known-rooms set.
In-flight requests still complete and their responses still reach
Elisp via `cmacs-libreclaw--on-cmacs-response'.  */)
  (Lisp_Object room_id)
{
  LcCmacsChannel *ch;

  CHECK_STRING (room_id);
  ch = get_cmacs_channel ();
  if (ch == NULL)
    return Qnil;
  lc_cmacs_channel_unregister_room (ch, SSDATA (room_id));
  return Qt;
}

DEFUN ("cmacs-libreclaw-cmacs-channel-list-rooms",
       Fcmacs_libreclaw_cmacs_channel_list_rooms,
       Scmacs_libreclaw_cmacs_channel_list_rooms, 0, 0, 0,
       doc: /* Return the list of known room ids on the cmacs channel.  */)
  (void)
{
  LcCmacsChannel *ch;
  GList *rooms;
  GList *l;
  Lisp_Object result = Qnil;

  ch = get_cmacs_channel ();
  if (ch == NULL)
    return Qnil;

  rooms = lc_cmacs_channel_list_rooms (ch);
  for (l = rooms; l != NULL; l = l->next)
    result = Fcons (build_string ((const char *) l->data), result);
  g_list_free_full (rooms, g_free);
  return Fnreverse (result);
}

DEFUN ("cmacs-libreclaw-cmacs-channel-has-room-p",
       Fcmacs_libreclaw_cmacs_channel_has_room_p,
       Scmacs_libreclaw_cmacs_channel_has_room_p, 1, 1, 0,
       doc: /* Return non-nil if ROOM-ID is registered on the cmacs channel.  */)
  (Lisp_Object room_id)
{
  LcCmacsChannel *ch;

  CHECK_STRING (room_id);
  ch = get_cmacs_channel ();
  if (ch == NULL)
    return Qnil;
  return lc_cmacs_channel_has_room (ch, SSDATA (room_id)) ? Qt : Qnil;
}

/* ── syms_of ──────────────────────────────────────────────────── */

void
syms_of_cmacs_libreclaw_cmacs_channel (void)
{
  DEFSYM (Qcmacs_libreclaw_on_cmacs_response,
          "cmacs-libreclaw--on-cmacs-response");

  defsubr (&Scmacs_libreclaw_cmacs_channel_available_p);
  defsubr (&Scmacs_libreclaw_cmacs_channel_inject);
  defsubr (&Scmacs_libreclaw_cmacs_channel_register_room);
  defsubr (&Scmacs_libreclaw_cmacs_channel_unregister_room);
  defsubr (&Scmacs_libreclaw_cmacs_channel_list_rooms);
  defsubr (&Scmacs_libreclaw_cmacs_channel_has_room_p);
}

#endif /* HAVE_CMACS_LIBRECLAW */
