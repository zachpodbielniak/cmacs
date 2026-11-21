/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-tool.h --- the `tool' command group's one hook into the
 * application: help that comes from the running editor. */

#ifndef CTL_CMD_TOOL_H
#define CTL_CMD_TOOL_H

#include "ctl-command-registry.h"
#include "ctl-invocation.h"

#include <json-glib/json-glib.h>

G_BEGIN_DECLS

void ctl_cmd_tool_register (CtlCommandRegistry *registry);

/* Fetch the capability table of the instance INV addresses: one
 * org.cmacs.Editor1.Tools.List.  On success *PARSER owns the document
 * and the returned array, its "tools" member, is borrowed from it; the
 * caller unrefs *PARSER.  NULL (with ERROR set, when given) when no
 * instance answers or it has no Tools interface.
 *
 * The verb aliases call this for --help only; running one never does
 * (ctl-cmd-alias.c). */
JsonArray *ctl_cmd_tool_table (CtlInvocation *inv, JsonParser **parser,
                               GError **error);

/* Print help for the words WORDS[0..N_WORDS), the first of which is
 * "tool", from the capability table of the instance INV addresses.
 *
 * Returns an exit code when it printed something, and -1 when the
 * request is not one it answers (`tool list --help', which has static
 * flags) or the table could not be fetched -- in which case it has
 * said why on stderr and the caller falls back to the static help. */
gint ctl_cmd_tool_help (CtlInvocation *inv, const gchar *prog,
                        gchar **words, gint n_words);

G_END_DECLS

#endif /* CTL_CMD_TOOL_H */
