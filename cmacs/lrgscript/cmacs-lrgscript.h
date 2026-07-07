/* cmacs-lrgscript.h --- Emacs Lisp scripting backend for libregnum (lisp side).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * cmacs-lrgscript makes Emacs Lisp a first-class libregnum scripting
 * language, *without* libregnum embedding an elisp runtime.  libregnum ships
 * a generic dynamic-backend registration hook
 * (lrg_scripting_manager_register_backend); this subsystem implements an
 * LrgScripting subclass (CmacsLrgScriptingElisp) that routes load/call/get/set
 * into the live Emacs Lisp VM, and registers it with the process-wide manager
 * at startup.  Because libregnum is whole-archive linked into the emacs
 * binary, this is one process with zero IPC.
 *
 * Firewall: raylib's `Color' (via <libregnum.h>) clashes with cmacs's
 * pgtkgui.h `Color', and by convention a translation unit includes either
 * <libregnum.h> OR lisp.h/pgtk headers, never both.  So:
 *
 *   cmacs-lrgscript-elisp.c   <libregnum.h>  -- the LrgScripting subclass;
 *                             delegates all Lisp work to the bridge via the
 *                             GValue + plain-C accessors in
 *                             cmacs-lrgscript-object.h.  Never lisp.h.
 *   cmacs-lrgscript-bridge.c  lisp.h         -- GValue <-> Lisp_Object
 *                             marshalling, read/eval, funcall, globals.
 *                             Never <libregnum.h>.
 *   cmacs-lrgscript-defuns.c  lisp.h         -- the cmacs-lrgscript-* DEFUNs.
 *   cmacs-lrgscript-init.c    lisp.h         -- syms_of/init_.
 *
 * This header is the lisp side: it re-exports the libregnum-side accessors
 * (via cmacs-lrgscript-object.h) plus the lisp-only bridge marshalling
 * helpers, for the DEFUN and init translation units. */

#ifndef CMACS_LRGSCRIPT_H
#define CMACS_LRGSCRIPT_H

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include "lisp.h"
#include <glib-object.h>
#include "cmacs-lrgscript-object.h"

/* ── syms_of aggregation (init.c) ─────────────────────────────────── */
extern void syms_of_cmacs_lrgscript_defuns (void);
extern void syms_of_cmacs_lrgscript_game_defuns (void);

/* ── bridge marshalling helpers (cmacs-lrgscript-bridge.c) ─────────────
 *
 * Lisp-side, so declared here where Lisp_Object is in scope.  Used by the
 * DEFUN layer to build/read the GValue arrays that cross to the object side. */
extern void        cmacs_lrgscript_bridge_lisp_to_gvalue (Lisp_Object v,
                                                          GValue *out);
extern Lisp_Object cmacs_lrgscript_bridge_gvalue_to_lisp (const GValue *v);

#endif /* HAVE_CMACS_LRGSCRIPT */
#endif /* CMACS_LRGSCRIPT_H */
