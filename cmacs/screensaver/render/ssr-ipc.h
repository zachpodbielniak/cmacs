/* ssr-ipc.h --- child-side control IPC over the inherited SEQPACKET socket.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Receives parent control messages (one JSON object per datagram) and routes
 * them to the renderer through a callbacks table; sends the child->parent
 * messages (the frame-buffer announce carries a memfd via SCM_RIGHTS).  The
 * hello/hello-ack version handshake and ping/pong are answered here. */

#ifndef SSR_IPC_H
#define SSR_IPC_H

#include <glib-object.h>
#include "cmacs-screensaver-proto.h"

G_BEGIN_DECLS

#define SSR_TYPE_IPC (ssr_ipc_get_type ())
G_DECLARE_FINAL_TYPE (SsrIpc, ssr_ipc, SSR, IPC, GObject)

/* Renderer-side handlers, invoked on the main loop as messages arrive. */
typedef struct
{
  void (*set_target)    (const ScrSetTarget *t, gpointer user);
  void (*remove_target) (int sink, const gchar *mon, gpointer user);
  void (*set_fps)       (int fps, gpointer user);
  void (*set_pause)     (gboolean paused, gpointer user);
  void (*quit)          (gpointer user); /* EOF/HUP, explicit quit, or bad version */
} SsrIpcCallbacks;

/* Wrap the inherited control FD (becomes owned).  CB/USER receive dispatched
 * messages.  Returns NULL on failure. */
SsrIpc *ssr_ipc_new (int fd, const SsrIpcCallbacks *cb, gpointer user);

/* child -> parent sends (all best-effort, non-fatal on a dead socket). */
gboolean ssr_ipc_send_frame_buffer (SsrIpc *self, const ScrFrameBuffer *fb,
                                    int memfd, GError **error);
void     ssr_ipc_send_load_result (SsrIpc *self, const ScrLoadResult *lr);
void     ssr_ipc_send_heartbeat (SsrIpc *self, gint64 seq);
void     ssr_ipc_send_stopped (SsrIpc *self, const gchar *reason);

G_END_DECLS

#endif /* SSR_IPC_H */
