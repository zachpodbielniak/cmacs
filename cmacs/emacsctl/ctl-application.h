/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-application.h --- CtlApplication, the top-level driver.
 *
 * Parses global options, loads the config, resolves the effective
 * context (flags > context > config defaults), expands aliases, and
 * dispatches into the command registry.  Behavior is argv[0]-
 * insensitive: emacsctl and cmacsctl act identically. */

#ifndef CTL_APPLICATION_H
#define CTL_APPLICATION_H

#include "ctl-command-registry.h"

G_BEGIN_DECLS

#define CTL_TYPE_APPLICATION (ctl_application_get_type ())
G_DECLARE_FINAL_TYPE (CtlApplication, ctl_application,
                      CTL, APPLICATION, GObject)

CtlApplication *ctl_application_new (void);

CtlCommandRegistry *ctl_application_get_registry (CtlApplication *self);

gint ctl_application_run (CtlApplication *self, gint argc, gchar **argv);

G_END_DECLS

#endif /* CTL_APPLICATION_H */
