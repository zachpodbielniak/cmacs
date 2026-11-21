/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-alias.h --- the transport-free half of the verb aliases.
 *
 * `emacsctl calc eval 2+2' predates the tool registry: it was a table
 * row naming org.cmacs.Editor1.Calc.Eval, a D-Bus method somebody wrote
 * for it.  The capability behind it is now the registry tool
 * `calc_eval', which `emacsctl tool calc eval --expression 2+2' already
 * reaches through org.cmacs.Editor1.Tools.Call.  An alias keeps the old
 * spelling and sends it down that same path.
 *
 * One CtlAliasSpec says everything an alias needs, so that running one
 * costs no round trip beyond the call itself:
 *
 *   tool      the wire name to call
 *   params    which tool parameter each positional argument is
 *   defaults  what to send for a positional that was left out, where
 *             the old method supplied a value the tool does not
 *   format    how to print the tool's text so the output is what the
 *             old verb printed
 *   timeout_s the tool's own allowance, when it is asynchronous
 *   legacy    the old table row, whole: its verb, summary, D-Bus
 *             method, argspec and reply kind
 *
 * `legacy' is not history.  Its argspec types the positionals (the tool
 * list is never fetched to run an alias), and its method is what the
 * alias calls instead when the target cmacs cannot serve the tool --
 * see ctl_alias_decide.
 *
 * Everything here works on values and touches neither D-Bus nor the
 * command registry, so the unit tests drive it directly.  The table
 * itself and the command class are in ctl-cmd-alias.c. */

#ifndef CTL_ALIAS_H
#define CTL_ALIAS_H

#include "ctl-command.h"
#include "ctl-result.h"

#include <json-glib/json-glib.h>

G_BEGIN_DECLS

/* How the tool's result becomes the old verb's output. */
typedef enum
{
  /* Print the text as it is (the old CTL_REPLY_STRING). */
  CTL_ALIAS_TEXT,
  /* A document when it parses as JSON, so -o json|yaml|table work on
   * it; the text itself when it does not (the old CTL_REPLY_JSON). */
  CTL_ALIAS_JSON,
  /* The tool answers as its MCP ancestor did, with the text printed by
   * `prin1' -- inside double quotes, `"' and `\' escaped.  The old
   * D-Bus method returned the bare text, so the quoting is undone. */
  CTL_ALIAS_PRINTED,
  /* As CTL_ALIAS_PRINTED, then one list row per line (the old
   * CTL_REPLY_STRLIST). */
  CTL_ALIAS_PRINTED_LINES
} CtlAliasFormat;

typedef struct
{
  const gchar *tool;
  const gchar *params;      /* "expression units", or NULL for none */
  const gchar *defaults;    /* "lines=50 path=x", or NULL */
  CtlAliasFormat format;
  gint timeout_s;           /* 0: the tool is synchronous */
  CtlMethodSpec legacy;
} CtlAliasSpec;

/* What to do about a failed Tools.Call. */
typedef enum
{
  /* The tool did not run and the old method may still answer: call
   * it. */
  CTL_ALIAS_FALLBACK,
  /* The failure is the answer.  Report it. */
  CTL_ALIAS_FAIL
} CtlAliasVerdict;

/* NULL when SPEC is well formed, else what is wrong with it (caller
 * g_frees): a tool name that is not a wire name, positionals that do
 * not pair one to one with distinct parameters, an argspec letter the
 * alias path cannot type, a default for something that is not a
 * positional.  The table is checked row by row in the unit tests, and
 * once at start-up in a debug build. */
gchar *ctl_alias_spec_problem (const CtlAliasSpec *spec);

/* The JSON object text Tools.Call takes, from the positionals
 * ARGV[0..ARGC).  Each is converted the way the old method command
 * converted it (the argspec letter decides), so `emacsctl gsurf zoom
 * 1.5' sends the number it always sent.  An optional positional that is
 * absent -- or is "", 0 or false, which is how the old wire spelt
 * absent -- is left out, unless SPEC has a default for it.
 * Positionals beyond the argspec are ignored, as they always were.
 *
 * Returns NULL with a CTL_ERROR_USAGE error when a required positional
 * is missing; the message is the old one.  Caller g_frees. */
gchar *ctl_alias_build_args (const CtlAliasSpec *spec, gchar **argv,
                             gint argc, GError **error);

/* Whether a failed Tools.Call should be retried through the old
 * method.
 *
 * It should exactly when the error proves the tool never started:
 *
 *   UnknownInterface, UnknownMethod   no org.cmacs.Editor1.Tools --
 *                                     an older cmacs, or one built
 *                                     without the registry
 *   NoSuchTool                        a registry, but not this tool
 *                                     (an older cmacs, a family that
 *                                     failed to load)
 *   NotOnSurface                      the tool was taken off D-Bus
 *   BadArguments                      refused before anything ran; the
 *                                     tool's parameters are not the
 *                                     ones this client was built for
 *
 * Everything else -- ToolFailed, Timeout, a dropped connection, no
 * instance -- is CTL_ALIAS_FAIL: the tool may have run, and running the
 * old method as well would do the work twice.
 *
 * ERROR is what ctl_transport_call set.  Over ssh the remote error name
 * arrives as the start of the message rather than as a GDBus remote
 * error; both are read. */
CtlAliasVerdict ctl_alias_decide (const GError *error);

/* The D-Bus timeout for calling SPEC's tool: BASE_MS, raised to cover
 * an asynchronous tool's own allowance.  -1 passes through. */
gint ctl_alias_timeout_ms (const CtlAliasSpec *spec, gint base_ms);

/* TEXT with `prin1' quoting undone, or a copy of TEXT when it is not a
 * printed string.  Caller g_frees. */
gchar *ctl_alias_unprint (const gchar *text);

/* The tool's result TEXT as the result the old verb emitted. */
CtlResult *ctl_alias_format_result (CtlAliasFormat format,
                                    const gchar *text);

/* The one-line summary for a group listing.  From TOOL -- the tool's
 * entry in the capability table -- when there is one: the first
 * sentence of its description.  From the built-in summary when TOOL is
 * NULL (no cmacs answered).  Either way it ends with the tool the verb
 * is an alias of.  Caller g_frees. */
gchar *ctl_alias_summary (const CtlAliasSpec *spec, JsonObject *tool);

/* `--help' for one alias.  With TOOL, the description and each
 * argument's text are the running editor's; with TOOL NULL the built-in
 * summary is shown and the text says so.  Caller g_frees. */
gchar *ctl_alias_help_string (const CtlAliasSpec *spec, JsonObject *tool,
                              const gchar *prog);

G_END_DECLS

#endif /* CTL_ALIAS_H */
