/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-tool-args.h --- the transport-free half of `emacsctl tool'.
 *
 * Everything here works on the capability table as the editor sent it
 * (org.cmacs.Editor1.Tools.List: {"version": N, "tools": [...]}) and
 * touches neither D-Bus nor the command registry, so the unit tests
 * can drive it with a table written in the test.  The commands
 * themselves are in ctl-cmd-tool.c. */

#ifndef CTL_TOOL_ARGS_H
#define CTL_TOOL_ARGS_H

#include "ctl.h"

#include <json-glib/json-glib.h>

G_BEGIN_DECLS

/* The tool called NAME in TOOLS, or NULL.  NAME is a wire name or one
 * of the tool's aliases; `-' and `_' are interchangeable, so the
 * registry spelling `calc-eval' finds `calc_eval'.  Borrowed. */
JsonObject *ctl_tool_find_by_name (JsonArray *tools, const gchar *name);

/* The tool whose "cli" member is "GROUP VERB", or NULL.  Borrowed. */
JsonObject *ctl_tool_find_by_cli (JsonArray *tools, const gchar *group,
                                  const gchar *verb);

/* Whether TOOL lists SURFACE ("cli", "dbus", ...) in its surfaces. */
gboolean ctl_tool_on_surface (JsonObject *tool, const gchar *surface);

/* Turn the command-line words ARGV[0..ARGC) into the JSON object text
 * Tools.Call takes, typed by TOOL's parameter list:
 *
 *   --NAME VALUE | --NAME=VALUE   string, integer, number
 *   --NAME [true|false]           boolean (bare flag = true)
 *   --no-NAME                     boolean false
 *   --json '{...}'                the whole object; flags override it
 *
 * `-' in a flag stands for `_' in the parameter name.  Returns NULL
 * with a CTL_ERROR_USAGE error for an unknown flag, a value of the
 * wrong type, a missing value, a stray positional, or a required
 * parameter that was not given.  Caller g_frees. */
gchar *ctl_tool_build_args (JsonObject *tool, gchar **argv, gint argc,
                            GError **error);

/* `--help' for one tool, rendered from its table entry.  Caller
 * g_frees. */
gchar *ctl_tool_help_string (JsonObject *tool, const gchar *prog);

/* `--help' for the tool command as a whole (GROUP NULL: every group
 * and verb) or for one GROUP.  NULL when GROUP names no group.  Caller
 * g_frees. */
gchar *ctl_tool_group_help_string (JsonArray *tools, const gchar *prog,
                                   const gchar *group);

/* The D-Bus timeout for calling TOOL: BASE_MS, raised to cover an
 * async tool's own timeout so the reply is not abandoned while the
 * tool is still inside its allowance.  -1 (GDBus default) passes
 * through for a synchronous tool. */
gint ctl_tool_timeout_ms (JsonObject *tool, gint base_ms);

G_END_DECLS

#endif /* CTL_TOOL_ARGS_H */
