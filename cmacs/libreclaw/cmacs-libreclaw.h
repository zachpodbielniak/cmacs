/* cmacs-libreclaw.h — LibreClaw chat/Matrix client integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Provides DEFUNs that embed libreclaw (liblc-1.0) inside Emacs,
 * sharing cmacs's existing podomation PodEngine and exposing Matrix,
 * Local, Email, and Webhook channels as cmacs room buffers.  See
 * lisp/cmacs/cmacs-libreclaw.el for the Elisp-facing layer and
 * doc_org/cmacs/libreclaw/ for the full manual. */

#ifndef CMACS_LIBRECLAW_H
#define CMACS_LIBRECLAW_H

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include "lisp.h"

/* Forward declarations so this header doesn't need to pull in the
 * full libreclaw umbrella.  The implementation files include
 * <libreclaw.h> directly. */
struct _LcApp;
struct _PodModule;

/* init_cmacs_libreclaw: called from emacs.c during startup.
 *
 * Intentionally empty — the engine is created from Elisp via
 * (cmacs-libreclaw-start), not at C init.  This keeps pdumper state
 * clean and avoids loading YAML before the user has configured
 * `cmacs-libreclaw-config-file'. */

/* syms_of_cmacs_libreclaw: called from emacs.c to register DEFUNs. */

/* Accessors for the shared cmacs-libreclaw state, used by other
 * cmacs subsystems (e.g. the pod bridge module) to reach the LcApp
 * without going through Elisp. */
extern struct _LcApp    *cmacs_libreclaw_get_app          (void);
extern struct _PodModule *cmacs_libreclaw_get_pod_module  (void);

/* Safely dispatch an Elisp symbol-call (FN ARG1 .. ARG5) from a
 * GLib signal callback.  Only string and nil/t arguments are
 * stringified automatically — for structured args (plists),
 * callers use cmacs_libreclaw_dispatch_expr() with a pre-built
 * expression. */
extern void cmacs_libreclaw_dispatch_to_lisp (Lisp_Object fn,
                                              Lisp_Object a1,
                                              Lisp_Object a2,
                                              Lisp_Object a3,
                                              Lisp_Object a4,
                                              Lisp_Object a5);

/* Dispatch a pre-formatted Lisp expression string through
 * cmacs_dispatch_eval.  Used by cmacs-libreclaw-room.c to fire
 * (cmacs-libreclaw--on-message "chan" "room" (:body "..." ...))
 * forms without having to marshal plists through Lisp_Object. */
extern void cmacs_libreclaw_dispatch_expr (const char *expression);

/* Room-buffer bridge — wires libreclaw signal handlers into the
 * running LcApp.  Called from cmacs_libreclaw_start after the LcApp
 * has been set up. */
extern void cmacs_libreclaw_room_wire_signals   (struct _LcApp *app);
extern void cmacs_libreclaw_room_unwire_signals (struct _LcApp *app);

/* Cmacs channel bridge — binds the in-process LcCmacsChannel
 * after the LcApp is up, and detaches before tear-down.  Defined
 * in cmacs-libreclaw-cmacs-channel.c. */
extern void cmacs_libreclaw_cmacs_channel_bind   (struct _LcApp *app);
extern void cmacs_libreclaw_cmacs_channel_unbind (void);

/* NOTE: error and dispatch symbols (Qcmacs_libreclaw_*) are
 * registered via DEFSYM in cmacs-libreclaw.c.  Emacs's build
 * machinery scans the DEFSYM calls and generates
 * `#define Q... builtin_lisp_symbol(N)` entries in src/globals.h,
 * so callers do NOT need an `extern Lisp_Object Q...;`
 * declaration — referring to the symbol by name pulls in the
 * builtin-symbol macro automatically. */

/* Per-file DEFUN registration entry points.  These are NOT in
   lisp.h -- only the subsystem's top-level syms_of_/init_ pair is
   -- so without them here each definition has no prototype.  */
extern void syms_of_cmacs_libreclaw_config (void);
extern void syms_of_cmacs_libreclaw_room (void);
extern void syms_of_cmacs_libreclaw_marshal (void);
extern void syms_of_cmacs_libreclaw_hatch (void);
extern void syms_of_cmacs_libreclaw_cmacs_channel (void);
extern void syms_of_cmacs_libreclaw_remote (void);

/* Marshalling helpers: a libreclaw message as a Lisp plist.
   Declared rather than made static because they are the subsystem's
   message-to-Lisp surface, not internals -- though nothing in-tree
   currently calls them, so they are also the first thing to check if
   this file ever looks larger than it needs to be.  */
extern Lisp_Object
cmacs_libreclaw_attachment_to_plist (const LcAttachment *att);
extern Lisp_Object
cmacs_libreclaw_inbound_to_plist (const LcInboundMessage *msg);
extern Lisp_Object
cmacs_libreclaw_outbound_to_plist (const LcOutboundMessage *msg);

#endif /* HAVE_CMACS_LIBRECLAW */

#endif /* CMACS_LIBRECLAW_H */
