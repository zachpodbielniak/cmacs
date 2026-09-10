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

/* syms_of_/init_ for each translation unit.  */
extern void syms_of_cmacs_clawtilla_defuns (void);

#endif /* CMACS_CLAWTILLA_H */
