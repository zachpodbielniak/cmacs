/* cmacs-libreclaw-room.c — Room/buffer signal bridging
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Connects libreclaw's LcChannelManager / LcSessionManager signals
 * into Elisp dispatch symbols.  Each handler marshals its arguments
 * via cmacs-libreclaw-marshal.c and then calls
 * cmacs_libreclaw_dispatch_to_lisp(), which wraps the eval in the
 * `waiting_for_input' clear/restore guard required for safe Lisp
 * eval from a GLib callback (see cmacs/glib/cmacs-glib-loop.c).
 *
 * The C side does NOT manage per-room buffer state — that all lives
 * in Elisp via `cmacs-libreclaw-rooms-alist' and `defvar-local'
 * buffer fields.  C only fires the dispatch; Elisp decides what to
 * do with the payload. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <glib.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"

/* Produce a Lisp-string literal for a possibly-NULL C string. */
static gchar *
qstr (const char *s)
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

/* Format an LcInboundMessage as a Lisp plist literal suitable for
 * inlining into an expression string. */
static gchar *
inbound_to_expr (const LcInboundMessage *msg)
{
  g_autofree gchar *ch = NULL;
  g_autofree gchar *sid = NULL;
  g_autofree gchar *sn = NULL;
  g_autofree gchar *rid = NULL;
  g_autofree gchar *tid = NULL;
  g_autofree gchar *body = NULL;

  if (msg == NULL)
    return g_strdup ("nil");

  ch   = qstr (lc_inbound_message_get_channel_id (msg));
  sid  = qstr (lc_inbound_message_get_sender_id (msg));
  sn   = qstr (lc_inbound_message_get_sender_name (msg));
  rid  = qstr (lc_inbound_message_get_room_id (msg));
  tid  = qstr (lc_inbound_message_get_thread_id (msg));
  body = qstr (lc_inbound_message_get_body (msg));

  return g_strdup_printf (
      "(list :channel-id %s :sender-id %s :sender-name %s "
      ":room-id %s :thread-id %s :body %s :timestamp %" G_GINT64_FORMAT ")",
      ch, sid, sn, rid, tid, body,
      (gint64) lc_inbound_message_get_timestamp (msg));
}

/* ── Tracked signal handler IDs ────────────────────────────────────── */

typedef struct {
  gulong message_received;
  gulong channel_registered;
} RoomSignals;

static RoomSignals g_room_signals = { 0, 0 };

/* Per-channel signal handler IDs (for connection-changed/error). */
static GHashTable *g_per_channel_signals = NULL;  /* LcChannel* -> GArray of gulong */

/* ── GLib signal handlers ──────────────────────────────────────────── */

static void
on_message_received_cb (LcChannelManager *mgr,
                        LcChannel        *channel,
                        LcInboundMessage *msg,
                        gpointer          user_data)
{
  g_autofree gchar *chan_q = NULL;
  g_autofree gchar *room_q = NULL;
  g_autofree gchar *plist  = NULL;
  g_autofree gchar *expr   = NULL;

  (void)mgr;
  (void)user_data;

  if (msg == NULL)
    return;

  chan_q = qstr (lc_channel_get_id (channel));
  room_q = qstr (lc_inbound_message_get_room_id (msg));
  plist  = inbound_to_expr (msg);
  expr   = g_strdup_printf ("(cmacs-libreclaw--on-message %s %s %s)",
                            chan_q, room_q, plist);

  cmacs_libreclaw_dispatch_expr (expr);
}

static void
on_connection_changed_cb (LcChannel *channel,
                          gboolean   connected,
                          gpointer   user_data)
{
  g_autofree gchar *chan_q = NULL;
  g_autofree gchar *expr   = NULL;
  (void)user_data;

  chan_q = qstr (lc_channel_get_id (channel));
  expr = g_strdup_printf ("(cmacs-libreclaw--on-channel-state %s %s)",
                          chan_q, connected ? "t" : "nil");
  cmacs_libreclaw_dispatch_expr (expr);
}

static void
on_channel_registered_cb (LcChannelManager *mgr,
                          LcChannel        *channel,
                          gpointer          user_data)
{
  GArray *ids;
  gulong h;

  (void)mgr;
  (void)user_data;

  if (g_per_channel_signals == NULL)
    g_per_channel_signals = g_hash_table_new_full (
        g_direct_hash, g_direct_equal, NULL,
        (GDestroyNotify) g_array_unref);

  ids = g_array_new (FALSE, FALSE, sizeof (gulong));
  h = g_signal_connect (channel, "connection-changed",
                        G_CALLBACK (on_connection_changed_cb), NULL);
  g_array_append_val (ids, h);
  g_hash_table_insert (g_per_channel_signals, channel, ids);
}

/* ── Public wire/unwire ────────────────────────────────────────────── */

void
cmacs_libreclaw_room_wire_signals (LcApp *app)
{
  LcChannelManager *mgr;
  GList *channels;
  GList *l;

  if (app == NULL)
    return;

  mgr = lc_app_get_channel_manager (app);
  if (mgr == NULL)
    return;

  g_room_signals.message_received =
    g_signal_connect (mgr, "message-received",
                      G_CALLBACK (on_message_received_cb), NULL);
  g_room_signals.channel_registered =
    g_signal_connect (mgr, "channel-registered",
                      G_CALLBACK (on_channel_registered_cb), NULL);

  /* Also wire any channels that were registered before we got here. */
  channels = lc_channel_manager_list_channels (mgr);
  for (l = channels; l != NULL; l = l->next)
    on_channel_registered_cb (mgr, l->data, NULL);
  g_list_free (channels);
}

void
cmacs_libreclaw_room_unwire_signals (LcApp *app)
{
  LcChannelManager *mgr;

  if (app == NULL)
    return;

  mgr = lc_app_get_channel_manager (app);
  if (mgr != NULL)
    {
      if (g_room_signals.message_received != 0)
        {
          g_signal_handler_disconnect (mgr, g_room_signals.message_received);
          g_room_signals.message_received = 0;
        }
      if (g_room_signals.channel_registered != 0)
        {
          g_signal_handler_disconnect (mgr, g_room_signals.channel_registered);
          g_room_signals.channel_registered = 0;
        }
    }

  /* Drop per-channel handlers — the hash-table free func will release
   * the arrays, but we must disconnect handlers first since the
   * channels outlive the hash table.  */
  if (g_per_channel_signals != NULL)
    {
      GHashTableIter it;
      gpointer key, value;

      g_hash_table_iter_init (&it, g_per_channel_signals);
      while (g_hash_table_iter_next (&it, &key, &value))
        {
          LcChannel *ch = key;
          GArray    *ids = value;
          guint      i;

          for (i = 0; i < ids->len; i++)
            g_signal_handler_disconnect (ch, g_array_index (ids, gulong, i));
        }
      g_clear_pointer (&g_per_channel_signals, g_hash_table_unref);
    }
}

void
syms_of_cmacs_libreclaw_room (void)
{
  /* No user-visible DEFUNs here — the room bridge is purely C-side
   * plumbing that feeds dispatch symbols defined in cmacs-libreclaw.c. */
}

#endif /* HAVE_CMACS_LIBRECLAW */
