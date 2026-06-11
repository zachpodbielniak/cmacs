/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-command-registry.h --- the command tree.
 *
 * Maps full command paths ("eval", "crispy eval", "get buffers") to
 * CtlCommand instances, preserving registration order for help
 * output.  Emits "command-added" so completion generation and future
 * plugin systems can react. */

#ifndef CTL_COMMAND_REGISTRY_H
#define CTL_COMMAND_REGISTRY_H

#include "ctl-command.h"

G_BEGIN_DECLS

#define CTL_TYPE_COMMAND_REGISTRY (ctl_command_registry_get_type ())
G_DECLARE_FINAL_TYPE (CtlCommandRegistry, ctl_command_registry,
                      CTL, COMMAND_REGISTRY, GObject)

CtlCommandRegistry *ctl_command_registry_new (void);

/* Takes ownership of COMMAND.  Emits "command-added". */
void ctl_command_registry_add (CtlCommandRegistry *self,
                               CtlCommand *command);

/* Longest-prefix lookup against ARGV: tries "argv0 argv1", then
 * "argv0".  *CONSUMED is set to the number of argv words matched. */
CtlCommand *ctl_command_registry_lookup (CtlCommandRegistry *self,
                                         gchar **argv, gint argc,
                                         gint *consumed);

/* Exact lookup by full name. */
CtlCommand *ctl_command_registry_get (CtlCommandRegistry *self,
                                      const gchar *name);

/* Registration-ordered iteration. */
guint       ctl_command_registry_get_n_commands (CtlCommandRegistry *self);
CtlCommand *ctl_command_registry_get_nth (CtlCommandRegistry *self,
                                          guint idx);

G_END_DECLS

#endif /* CTL_COMMAND_REGISTRY_H */
