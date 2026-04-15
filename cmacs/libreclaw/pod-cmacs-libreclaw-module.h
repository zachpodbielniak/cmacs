/* pod-cmacs-libreclaw-module.h — Podomation bridge for libreclaw
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A PodModule (dual role: event source + event handler) that bridges
 * libreclaw GObject signals into podomation DSL events, and
 * podomation handler actions back into libreclaw API calls.
 *
 * Registered on cmacs's shared PodEngine by `cmacs-libreclaw-start'.
 * Follows the same structure as pod-cmacs-module.c / pod-gowl-module.c
 * and is compiled into temacs (no external .so).
 *
 * Events emitted (prefix `on_cm_lc_'):
 *   on_cm_lc_message              — incoming inbound message
 *   on_cm_lc_response             — outgoing outbound message
 *   on_cm_lc_room_joined          — channel joined a room
 *   on_cm_lc_room_removed         — channel left / removed a room
 *   on_cm_lc_channel_connected    — connection opened
 *   on_cm_lc_channel_disconnected — connection closed
 *   on_cm_lc_channel_error        — channel error
 *   on_cm_lc_session_created      — session spawned
 *   on_cm_lc_session_destroyed    — session reaped
 *
 * Handler actions supported:
 *   send_message(channel, room, body)
 *   join_room(channel, room)
 *   leave_room(channel, room)
 *   set_buffer_property(channel, room, key, value)  (Elisp-side only)
 */

#pragma once

#include <glib-object.h>

G_BEGIN_DECLS

struct _LcApp;
struct _PodModule;

/* Constructor — returns a PodModule* (so callers don't need to
 * include the full GObject-type boilerplate for this internal type). */
struct _PodModule *pod_cmacs_libreclaw_module_new (void);

/* Point the module at a running LcApp so it can call
 * libreclaw APIs from handler actions and read channel/session
 * state when emitting events.  Must be called AFTER
 * pod_cmacs_libreclaw_module_new() and BEFORE the engine dispatches
 * any events at the module. */
void
pod_cmacs_libreclaw_module_set_app (struct _PodModule *self,
                                    struct _LcApp     *app);

G_END_DECLS
