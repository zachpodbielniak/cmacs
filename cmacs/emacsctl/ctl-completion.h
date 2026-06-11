/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-completion.h --- shell completion (`completion bash|zsh' and
 * the hidden `__complete' command). */

#ifndef CTL_COMPLETION_H
#define CTL_COMPLETION_H

#include "ctl-command-registry.h"
#include "ctl-invocation.h"

G_BEGIN_DECLS

/* Print the static bash/zsh script (which delegates every completion
 * to `emacsctl __complete -- <words>'). */
gint ctl_completion_print_script (const gchar *shell, GError **error);

/* The hidden `__complete' command body: argv holds the words typed so
 * far (after "--"); prints one candidate per line. */
gint ctl_completion_complete (CtlCommandRegistry *registry,
                              CtlInvocation *inv);

G_END_DECLS

#endif /* CTL_COMPLETION_H */
