/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-bacon-ipc.h — parent-side socketpair IPC for CMacs ↔ bacon
 *
 * Reads requests from the forked bacon child over a Unix socketpair,
 * dispatches them to Emacs via cmacs-eval-dispatch, and writes
 * responses back.  Integrates with the CMacs GMainContext.
 *
 * Wire protocol: length-prefixed JSON messages.
 *   [4 bytes: uint32 big-endian length] [length bytes: JSON payload]
 *
 * Request:  {"id":N, "method":"Eval", "params":{"expression":"..."}}
 * Response: {"id":N, "result":"..."} or {"id":N, "error":"..."}
 */

#ifndef CMACS_BACON_IPC_H
#define CMACS_BACON_IPC_H

#include <config.h>

#ifdef HAVE_CMACS_BACON

#include <glib.h>

typedef struct _CmacsBaconIpc CmacsBaconIpc;

/* Create the parent-side IPC handler on FD, attached to CTX.
   Takes ownership of FD (closes it on destroy). */
CmacsBaconIpc *cmacs_bacon_ipc_new (int fd, GMainContext *ctx);

/* Shut down and free the IPC handler, closing the fd. */
void cmacs_bacon_ipc_destroy (CmacsBaconIpc *ipc);

#endif /* HAVE_CMACS_BACON */
#endif /* CMACS_BACON_IPC_H */
