/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-internal.h --- compatibility shim
 *
 * The cmacsgi command implementations have been extracted into the
 * shared cmacs-api library (cmacs/api/).  This header provides
 * backward-compatible typedefs and macros so that the remaining
 * bacon-specific code (cmacs-gi-command.c) continues to compile
 * against the new API without changes.
 */

#ifndef CMACS_GI_CMD_INTERNAL_H
#define CMACS_GI_CMD_INTERNAL_H

#include "../../api/cmacs-api.h"

/* Type aliases: old bacon-specific names → new shared names. */
typedef CmacsApiTransport  CmacsGiTransport;
typedef CmacsApiHandler    CmacsGiHandler;
typedef CmacsApiSubcmd     CmacsGiSubcmd;

/* Function aliases. */
#define cmacs_gi_transport_new    cmacs_api_transport_new
#define cmacs_gi_transport_free   cmacs_api_transport_free
#define cmacs_gi_transport_call   cmacs_api_transport_call
#define cmacs_gi_eval_print       cmacs_api_eval_print
#define cmacs_gi_eval_quiet       cmacs_api_eval_quiet
#define cmacs_gi_eval_get_string  cmacs_api_eval_get_string
#define cmacs_gi_lisp_escape      cmacs_api_lisp_escape
#define cmacs_gi_lisp_quote       cmacs_api_lisp_quote
#define cmacs_gi_dispatch_group   cmacs_api_dispatch_group
#define cmacs_gi_print_group_help cmacs_api_print_group_help
#define cmacs_gi_get_transport    cmacs_api_transport_new

#endif /* CMACS_GI_CMD_INTERNAL_H */
