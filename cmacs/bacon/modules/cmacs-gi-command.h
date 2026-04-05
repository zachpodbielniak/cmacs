/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-command.h — `cmacsgi` bacon builtin: interact with CMacs
 *                       via GObject Introspection over D-Bus
 */

#ifndef CMACS_GI_COMMAND_H
#define CMACS_GI_COMMAND_H

#define BACON_COMPILATION
#include <glib-object.h>
#include <commands/bacon-command.h>

G_BEGIN_DECLS

#define CMACS_TYPE_GI_COMMAND (cmacs_gi_command_get_type())

G_DECLARE_FINAL_TYPE(CmacsGiCommand, cmacs_gi_command, CMACS, GI_COMMAND, BaconCommand)

CmacsGiCommand *cmacs_gi_command_new(void);

G_END_DECLS

#endif /* CMACS_GI_COMMAND_H */
