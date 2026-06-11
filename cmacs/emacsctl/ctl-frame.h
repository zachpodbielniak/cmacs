/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-frame.h --- the emacsctl proxy wire protocol.
 *
 * Framing: 4-byte big-endian payload length, then a JSON object.
 * (Same framing as the cmacs FD transport in
 * cmacs/api/cmacs-api-transport.c, so the codec is familiar.)
 *
 * Frame types (proto 1):
 *   {"type":"hello","proto":1,"version":"..."}        both directions
 *   {"id":N,"type":"call","iface":I,"method":M,
 *    "sig":"(ss)","params":[...]}                     client -> proxy
 *   {"id":N,"type":"reply","sig":"(s)","result":[..]} proxy -> client
 *   {"id":N,"type":"error","name":"...","message":..} proxy -> client
 *   {"id":N,"type":"subscribe","iface":I,"signal":S}  client -> proxy
 *   {"type":"unsubscribe","sub":N}                    client -> proxy
 *   {"type":"signal","sub":N,"iface":I,"signal":S,
 *    "sig":"(s)","args":[...]}                        proxy -> client
 *
 * GVariant <-> JSON uses json-glib's signature-directed
 * json_gvariant_serialize / json_gvariant_deserialize. */

#ifndef CTL_FRAME_H
#define CTL_FRAME_H

#include "ctl.h"
#include <json-glib/json-glib.h>

G_BEGIN_DECLS

#define CTL_FRAME_PROTO 1

/* Read one frame.  Returns NULL with *EOF_SEEN=TRUE on clean EOF,
 * NULL with *ERROR set otherwise.  Caller json_object_unrefs. */
JsonObject *ctl_frame_read  (GInputStream *in, gboolean *eof_seen,
                             GError **error);

/* Write one frame (takes no ownership). */
gboolean    ctl_frame_write (GOutputStream *out, JsonObject *frame,
                             GError **error);

/* Convenience constructors. */
JsonObject *ctl_frame_new       (const gchar *type);
JsonObject *ctl_frame_new_hello (void);

/* Embed VARIANT under KEY (+KEY_sig) in FRAME; NULL is fine. */
void ctl_frame_set_variant (JsonObject *frame, const gchar *key,
                            GVariant *variant);
/* Extract the variant stored under KEY (+KEY_sig); NULL if absent. */
GVariant *ctl_frame_get_variant (JsonObject *frame, const gchar *key,
                                 GError **error);

G_END_DECLS

#endif /* CTL_FRAME_H */
