/* Clawtilla fleet client for CMacs -- internal interface.

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later  */

#ifndef CMACS_CLAWTILLA_H
#define CMACS_CLAWTILLA_H

#include <stdbool.h>
#include <stdint.h>

/* ------------------------------------------------------------------
   The split in this subsystem, and why it is worth keeping.

   `cmacs-clawtilla-client.c' sees <clawtilla.h> and never sees
   `lisp.h'.  `cmacs-clawtilla-defuns.c' sees `lisp.h' and never sees
   <clawtilla.h>.  Everything crossing between them is a C string, an
   integer or a bool -- declared below -- so no `Lisp_Object' is ever
   stored in GLib-allocated memory, which is the GC-roots invariant, and
   the transport half stays testable without an Emacs.

   A connection is an integer HANDLE rather than a pointer.  A client
   that has been closed while a reply was in flight then leaves a stale
   handle that fails to look up, instead of a dangling pointer that does
   not.

   A callback is an integer COOKIE from `cmacs_dispatch_callback_register'
   for the same reason, and it is spent exactly once: the C side drops it
   after delivering, so a reply that somehow arrives twice cannot call
   Lisp twice.
   ------------------------------------------------------------------ */

/* Delivered by the transport half; implemented in the DEFUN half.  */
extern void cmacs_clawt_deliver_reply (uint64_t cookie, const char *json,
                                       const char *error);
extern void cmacs_clawt_deliver_event (uint64_t handle, const char *kind,
                                       const char *json);
extern void cmacs_clawt_deliver_state (uint64_t handle, const char *state);

/* Implemented by the transport half; called from the DEFUN half.  */
extern void cmacs_clawt_init (void);
extern uint64_t cmacs_clawt_connect_local (const char *socket_path,
                                           uint64_t cookie);
extern uint64_t cmacs_clawt_connect_tcp (const char *host, int port,
                                         const char *token, bool tls,
                                         bool accept_unknown_certificate,
                                         uint64_t cookie);
extern bool cmacs_clawt_request (uint64_t handle, const char *kind,
                                 const char *payload_json, uint64_t cookie);
extern bool cmacs_clawt_subscribe (uint64_t handle, uint64_t cursor,
                                   uint64_t cookie);
extern bool cmacs_clawt_disconnect (uint64_t handle);
extern bool cmacs_clawt_close (uint64_t handle);
extern bool cmacs_clawt_is_connected (uint64_t handle);
extern bool cmacs_clawt_is_reconnecting (uint64_t handle);
extern bool cmacs_clawt_set_auto_reconnect (uint64_t handle, bool enabled);
extern uint64_t cmacs_clawt_cursor (uint64_t handle);
extern char *cmacs_clawt_default_socket_path (void);
extern char *cmacs_clawt_handle_list_json (void);

/* Frees what the transport half allocated.  The DEFUN half deliberately
   sees no GLib header, so it cannot call g_free itself -- and a string
   from g_malloc handed to xfree is not a portability detail, it is two
   allocators sharing one pointer.  */
extern void cmacs_clawt_free (char *text);

/* The library's own enumerations, walked rather than copied.

   Every one of these exists so a client can offer a set of values
   without naming them.  `make parity' in clawtilla fails a client that
   contains one of the values as a literal, because having the list is
   what makes a client able to disagree with it.  */
extern char *cmacs_clawt_enum_json (const char *family);

/* Saved connection profiles, read from and written to the same
   ~/.config/clawtilla/connections.yaml every other clawtilla client
   uses -- so a profile added in the GTK client is simply there, and the
   advice shown for an unreachable daemon is one sentence rather than
   three that drifted.  */
extern char *cmacs_clawt_connections_path (void);
extern char *cmacs_clawt_connections_json (const char *path, char **error);
extern uint64_t cmacs_clawt_connect_profile (const char *path,
                                             const char *name,
                                             uint64_t cookie, char **error);
extern char *cmacs_clawt_link_notice (uint64_t handle, const char *name,
                                      bool ever_connected, bool remembered);

/* Shared presentation helpers.

   Each of these is a decision libclawt already makes and every
   clawtilla client is required to reach for rather than answer itself;
   `make parity' compares which shared symbols each client touches so a
   third one cannot quietly grow its own opinion.  Markdown crosses as
   Pango markup because Emacs wants text properties, not markup -- the
   shared thing is the cmark parse, not the output.  */
extern char *cmacs_clawt_activity_label (bool busy, const char *peer);
extern char *cmacs_clawt_team_tally_json (const char *agents_json,
                                          const char *team_id);
extern bool cmacs_clawt_unread_should_count (const char *room_id,
                                             const char *viewing,
                                             const char *from,
                                             int64_t event_ts,
                                             int64_t connected_at,
                                             const char *rooms_json);
extern char *cmacs_clawt_run_is_start (const char *previous_sender,
                                       const char *previous_day,
                                       const char *sender, const char *day);
extern char *cmacs_clawt_chat_time_label (int64_t unix_seconds);
extern char *cmacs_clawt_chat_day_label (int64_t unix_seconds);
extern char *cmacs_clawt_alert_tier (const char *kind, const char *subject,
                                     int64_t timestamp);
extern bool cmacs_clawt_alert_arrives_read (bool surface_showing,
                                            const char *tier);
extern char *cmacs_clawt_markdown (const char *markdown);
extern char *cmacs_clawt_step_summary (const char *steps_json,
                                       const char *agent_id, int from,
                                       int to);
extern char *cmacs_clawt_step_tone (const char *step_json,
                                    const char *agent_id);
extern bool cmacs_clawt_step_precedes (const char *step_json,
                                       const char *agent_id,
                                       int64_t message_ts);
extern char *cmacs_clawt_steps_split (const char *steps_json,
                                      const char *agent_id,
                                      int64_t message_ts);

/* The Activity page, the Fleet page and the browser line, each worded
   by libclawt (clawt-activity.h, clawt-usage.h, clawt-browser.h).
   `cmacs_clawt_usage_fleet_json' takes a usage.summary reply exactly as
   the daemon sent it and answers everything the page draws from it --
   the summary, the budget line, the strip, and per agent its cost,
   share, subtitle, daily strip and whether Stop is offered.  */
extern char *cmacs_clawt_activity_elapsed (int64_t started_us,
                                           int64_t now_us);
extern char *cmacs_clawt_activity_stop_prompt (const char *agent_id,
                                               unsigned running);
extern char *cmacs_clawt_usage_sparkline (const int64_t *values,
                                          unsigned count);
extern char *cmacs_clawt_usage_format_cost (int64_t cost_micros);
extern char *cmacs_clawt_usage_fleet_payload (int period, int days);
extern char *cmacs_clawt_usage_fleet_json (const char *reply_json,
                                           int64_t now);
extern char *cmacs_clawt_browser_session_line (const char *session_json);

/* One door for everything else libclawt words (cmacs-clawtilla-render.c
   has the table): WHAT names a question, ARGS-JSON is a JSON object of
   its arguments, and the answer is text -- JSON text when it has more
   than one part -- or NULL for no answer.  `cmacs_clawt_ask_names' is
   the table's own list of questions.  */
extern char *cmacs_clawt_ask (const char *what, const char *args_json);
extern char *cmacs_clawt_ask_names (void);

/* Which daemon a client starts on, and remembering it (clawt-connection.h).

   `cmacs_clawt_connection_choice_json' is clawt_connection_choose with
   nothing named: the profile this client was last switched to, else the
   local daemon -- as `{"name","local","describe","from_last","notice"}'.
   `cmacs_clawt_last_save' records the profile NAME for the next start
   (NULL or a local one removes the record), and `cmacs_clawt_last_load'
   reads it back.  `cmacs_clawt_offer_local' is whether a client that
   cannot reach HANDLE's daemon should offer the local one instead.  */
extern char *cmacs_clawt_connection_choice_json (char **error);
extern char *cmacs_clawt_last_load (void);
extern bool cmacs_clawt_last_save (const char *name, char **error);
extern bool cmacs_clawt_offer_local (uint64_t handle, const char *name,
                                     bool ever_connected, bool remembered);

/* Pairing this machine with a daemon, off the main thread.

   clawt_connection_new_paired() trades a six-digit code for a device
   token over the network and blocks while it does, so it runs on a
   worker and the outcome is delivered to COOKIE on the cmacs GLib
   context like any other reply: `{"name": ...}' for the saved profile,
   or an error string.  Returns false when nothing was started.  */
extern bool cmacs_clawt_pair (const char *name, const char *host, int port,
                              bool tls, bool accept_unknown_certificate,
                              const char *code, const char *device_name,
                              uint64_t cookie);

/* syms_of_/init_ for each translation unit.  */
extern void syms_of_cmacs_clawtilla_defuns (void);

#endif /* CMACS_CLAWTILLA_H */
