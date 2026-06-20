/* ssr-renderer.h --- the screensaver render engine (child process core).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Owns the single libregnum/raylib GL context and one off-screen render target
 * (a loaded game module + FBO + shared-memory frame ring) per (sink, monitor).
 * A timer renders every uncovered, unpaused target at the configured FPS and
 * publishes frames into shared memory; a second timer sends heartbeats.  The
 * SsrIpc instance feeds it control messages and carries frames' memfds out. */

#ifndef SSR_RENDERER_H
#define SSR_RENDERER_H

#include <glib-object.h>

G_BEGIN_DECLS

#define SSR_TYPE_RENDERER (ssr_renderer_get_type ())
G_DECLARE_FINAL_TYPE (SsrRenderer, ssr_renderer, SSR, RENDERER, GObject)

/* IPC_FD is the inherited control socket; LOOP is quit on EOF / `quit' / idle.
 * Returns NULL on failure (e.g. the control fd is unusable). */
SsrRenderer *ssr_renderer_new (int ipc_fd, GMainLoop *loop);

G_END_DECLS

#endif /* SSR_RENDERER_H */
