/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-alias.h --- the verbs that are aliases of registry tools.
 *
 * The table, the command class that runs a row, and the list of verbs
 * that are deliberately NOT aliases with the reason for each.  The
 * row type and everything that can be computed from a row without an
 * editor are in ctl-alias.h. */

#ifndef CTL_CMD_ALIAS_H
#define CTL_CMD_ALIAS_H

#include "ctl-alias.h"
#include "ctl-command-registry.h"
#include "ctl-invocation.h"

G_BEGIN_DECLS

/* A placeholder in a ctl-cmd-*.c verb table: "this verb is an alias;
 * its row is in ctl-cmd-alias.c".  It keeps the verb at its place in
 * the table, which is what orders the groups in `emacsctl --help'. */
#define CTL_ALIAS_ROW(verb) { verb, NULL, NULL, NULL, NULL, CTL_REPLY_NONE }

#define CTL_TYPE_ALIAS_COMMAND (ctl_alias_command_get_type ())
G_DECLARE_FINAL_TYPE (CtlAliasCommand, ctl_alias_command,
                      CTL, ALIAS_COMMAND, CtlCommand)

/* The command for the alias row whose verb is VERB.  It is a
 * programming error for there to be none: a CTL_ALIAS_ROW without a row
 * here aborts at start-up, and the unit tests run every registration. */
CtlCommand *ctl_cmd_alias_new (const gchar *verb);

/* SPEC as a command: a method command for an ordinary row, the alias
 * command for a CTL_ALIAS_ROW.  What the ctl-cmd-*.c register loops
 * call for each row of their tables. */
CtlCommand *ctl_cmd_alias_command_for_row (const CtlMethodSpec *spec);

const CtlAliasSpec *ctl_alias_command_get_spec (CtlAliasCommand *self);

/* The whole table: N_OUT rows. */
const CtlAliasSpec *ctl_cmd_alias_specs (guint *n_out);

/* The row for VERB ("calc eval"), or NULL. */
const CtlAliasSpec *ctl_cmd_alias_find (const gchar *verb);

/* Why VERB is hand-written rather than an alias, or NULL when nothing
 * records a reason.  Every verb that is not an alias has to have one;
 * the unit tests refuse a new verb without. */
const gchar *ctl_cmd_alias_kept_reason (const gchar *verb);

/* The recorded reasons, for the tests: N_OUT (pattern, reason) pairs,
 * PATTERN being a verb or "GROUP *". */
typedef struct
{
  const gchar *pattern;
  const gchar *reason;
} CtlKeptVerb;

const CtlKeptVerb *ctl_cmd_alias_kept (guint *n_out);

/* Help for WORDS[0..N_WORDS) when it concerns an alias.
 *
 * For an alias verb: prints its help, with the description and
 * arguments taken from the running editor's capability table, and
 * returns an exit code.
 *
 * For a group that has alias verbs: replaces their one-line summaries
 * with the table's and returns -1, so the caller's ordinary group
 * renderer prints them.
 *
 * Returns -1 without doing anything for every other request. */
gint ctl_cmd_alias_help (CtlInvocation *inv, CtlCommandRegistry *registry,
                         const gchar *prog, gchar **words, gint n_words);

G_END_DECLS

#endif /* CTL_CMD_ALIAS_H */
