/* cmacs-libreclaw-marshal.c — Boxed-type ↔ Elisp plist marshaling
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Helpers that convert libreclaw's boxed types (LcInboundMessage,
 * LcOutboundMessage, LcAttachment, LcChannelInfo) to/from Elisp
 * plists for the signal dispatch path.  The Elisp handler receives
 * a plist, not a GObject ref, so there's no GC-safety concern around
 * keeping Lisp_Object handles alive in GLib-owned memory.
 *
 * Every helper is safe to call with NULL input. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <string.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"

/* Convert a possibly-NULL UTF-8 C string to a Lisp string, or Qnil. */
static Lisp_Object
cstr_or_nil (const char *s)
{
  if (s == NULL)
    return Qnil;
  return build_string (s);
}

/* ── LcAttachment → plist ──────────────────────────────────────────── */

Lisp_Object
cmacs_libreclaw_attachment_to_plist (const LcAttachment *att)
{
  Lisp_Object plist = Qnil;

  if (att == NULL)
    return Qnil;

  plist = Fcons (intern (":size"),
                 Fcons (make_fixnum ((EMACS_INT)
                                     lc_attachment_get_size (att)),
                        plist));
  plist = Fcons (intern (":mime-type"),
                 Fcons (cstr_or_nil (lc_attachment_get_mime_type (att)),
                        plist));
  plist = Fcons (intern (":url"),
                 Fcons (cstr_or_nil (lc_attachment_get_url (att)),
                        plist));
  plist = Fcons (intern (":filename"),
                 Fcons (cstr_or_nil (lc_attachment_get_filename (att)),
                        plist));
  return plist;
}

/* ── LcInboundMessage → plist ──────────────────────────────────────── */

Lisp_Object
cmacs_libreclaw_inbound_to_plist (const LcInboundMessage *msg)
{
  Lisp_Object plist = Qnil;

  if (msg == NULL)
    return Qnil;

  /* Build the plist in reverse; the final list reads as
   * (:channel-id .. :sender-id .. :body .. ...) */
  plist = Fcons (intern (":timestamp"),
                 Fcons (make_fixnum ((EMACS_INT)
                                     lc_inbound_message_get_timestamp (msg)),
                        plist));
  plist = Fcons (intern (":thread-id"),
                 Fcons (cstr_or_nil (lc_inbound_message_get_thread_id (msg)),
                        plist));
  plist = Fcons (intern (":body"),
                 Fcons (cstr_or_nil (lc_inbound_message_get_body (msg)),
                        plist));
  plist = Fcons (intern (":room-id"),
                 Fcons (cstr_or_nil (lc_inbound_message_get_room_id (msg)),
                        plist));
  plist = Fcons (intern (":sender-name"),
                 Fcons (cstr_or_nil (lc_inbound_message_get_sender_name (msg)),
                        plist));
  plist = Fcons (intern (":sender-id"),
                 Fcons (cstr_or_nil (lc_inbound_message_get_sender_id (msg)),
                        plist));
  plist = Fcons (intern (":channel-id"),
                 Fcons (cstr_or_nil (lc_inbound_message_get_channel_id (msg)),
                        plist));
  return plist;
}

/* ── LcOutboundMessage → plist ─────────────────────────────────────── */

Lisp_Object
cmacs_libreclaw_outbound_to_plist (const LcOutboundMessage *msg)
{
  Lisp_Object plist = Qnil;

  if (msg == NULL)
    return Qnil;

  plist = Fcons (intern (":thread-id"),
                 Fcons (cstr_or_nil (lc_outbound_message_get_thread_id (msg)),
                        plist));
  plist = Fcons (intern (":html-body"),
                 Fcons (cstr_or_nil (lc_outbound_message_get_html_body (msg)),
                        plist));
  plist = Fcons (intern (":body"),
                 Fcons (cstr_or_nil (lc_outbound_message_get_body (msg)),
                        plist));
  plist = Fcons (intern (":target-user"),
                 Fcons (cstr_or_nil (lc_outbound_message_get_target_user (msg)),
                        plist));
  plist = Fcons (intern (":target-room"),
                 Fcons (cstr_or_nil (lc_outbound_message_get_target_room (msg)),
                        plist));
  plist = Fcons (intern (":channel-id"),
                 Fcons (cstr_or_nil (lc_outbound_message_get_channel_id (msg)),
                        plist));
  return plist;
}

void
syms_of_cmacs_libreclaw_marshal (void)
{
  /* Nothing to register — these are C-internal helpers only. */
}

#endif /* HAVE_CMACS_LIBRECLAW */
