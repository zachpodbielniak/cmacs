/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl.h --- umbrella header for emacsctl/cmacsctl.
 *
 * emacsctl is a standalone kubectl-style command-line client for a
 * running cmacs instance.  It talks to the editor over the session
 * D-Bus (org.cmacs.Editor / org.cmacs.Editor.Pid<N> at
 * /org/cmacs/Editor), or over an ssh-tunnelled stdio proxy for
 * remote hosts.  It links NO Emacs objects and NO vendored archives:
 * just GLib/GObject, GIO, json-glib and yaml-glib. */

#ifndef CTL_H
#define CTL_H

#include <glib.h>
#include <glib-object.h>
#include <gio/gio.h>

G_BEGIN_DECLS

#define CTL_VERSION "1.0.0"

/* Exit codes (stable, scriptable). */
enum
{
  CTL_EXIT_OK          = 0,  /* success */
  CTL_EXIT_ERROR       = 1,  /* generic / remote error */
  CTL_EXIT_USAGE       = 2,  /* bad usage */
  CTL_EXIT_UNSUPPORTED = 3,  /* iface/method missing on the server */
  CTL_EXIT_NO_INSTANCE = 4   /* instance not found or ambiguous */
};

/* Quark for emacsctl client-side errors. */
#define CTL_ERROR (ctl_error_quark ())
GQuark ctl_error_quark (void);

enum
{
  CTL_ERROR_FAILED,
  CTL_ERROR_USAGE,
  CTL_ERROR_UNSUPPORTED,
  CTL_ERROR_NO_INSTANCE
};

/* Map a GError (ours or GDBus's) to an exit code. */
gint ctl_exit_code_for_error (const GError *error);

G_END_DECLS

#endif /* CTL_H */
