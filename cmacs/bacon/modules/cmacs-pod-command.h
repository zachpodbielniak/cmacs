/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-pod-command.h — `pod` bacon builtin for the podomation engine */

#ifndef CMACS_POD_COMMAND_H
#define CMACS_POD_COMMAND_H

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include <glib-object.h>
#include <commands/bacon-command.h>

G_BEGIN_DECLS

#define CMACS_TYPE_POD_COMMAND (cmacs_pod_command_get_type())

G_DECLARE_FINAL_TYPE(CmacsPodCommand, cmacs_pod_command, CMACS, POD_COMMAND, BaconCommand)

CmacsPodCommand *cmacs_pod_command_new(void);

G_END_DECLS

#endif /* CMACS_POD_COMMAND_H */
