/* cmacs-brigade-allowlist.c --- the tool authorisation gate.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Decides whether an agent may call a tool.  Three properties matter and
 * each of them is why this is C rather than Elisp:
 *
 *   1. It is not rewritable by its subject.  An allowlist implemented in
 *      Lisp is only as strong as the weakest tool: any agent that can
 *      reach `eval' can redefine the function that decides what it is
 *      allowed to do.  This one cannot be reached from Lisp at all
 *      except through a read-only predicate.
 *
 *   2. It is reachable from the relay.  `emacs --mcp-relay' filters a
 *      CLI agent's tool set before any Lisp VM exists in that process,
 *      so the decision has to be a plain C function over a string.
 *
 *   3. It fails closed.  An unparseable or empty allowlist grants
 *      nothing.  The privileged set below is denied even to "*".
 *
 * The gate is a filter, not just a check: an in-process agent is handed
 * an executor containing only the tools it passed, so an unauthorised
 * call is not merely refused, it is unrepresentable.  The predicate is
 * defence in depth for the paths where filtering is not possible. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>
#include <string.h>

/* Tools that hand an agent the whole machine.  Naming one of these in an
 * allowlist works; matching one via "*" or a group does not.  The point
 * is that granting a capability has to be a deliberate act, not a side
 * effect of granting something broad.
 *
 * `eval' and `bash'/`shell' are obvious.  The C-patching tools are here
 * because cmacs can rewrite its own running code: an agent with
 * cmacs_c_patch_defun can replace this very function.  `write'/`edit'
 * are not privileged -- writing files is ordinary agent work, and that
 * is what isolation backends are for. */
static const gchar *const cmacs_brigade__privileged[] = {
  "eval",
  "bash",
  "shell",
  "execute_command",
  "send_keys",
  "cmacs_c_patch_defun",
  "cmacs_c_unpatch_defun",
  "cmacs_c_unpatch_all",
  "cmacs_c_compile_snippet",
  "cmacs_c_call_handle",
  "crispy_eval",
  "bacon_eval",
  "podomation_eval_dsl",
  "podomation_repl_eval",
  NULL
};

/* Prefixes an agent may never call regardless of allowlist.
 *
 * brigade_ would let an agent spawn agents outside the orchestrator's
 * accounting and budget; ai_ is the same recursion guard cmacs-ai's MCP
 * bridge already applies (cmacs/ai/cmacs-ai-mcp-bridge.c), kept here so
 * the two paths cannot drift. */
static const gchar *const cmacs_brigade__blocked_prefixes[] = {
  "ai_",
  "brigade_",
  NULL
};

gboolean
cmacs_brigade_tool_privileged (const gchar *tool_name)
{
  gsize i;

  if (tool_name == NULL) return TRUE;   /* fail closed */
  for (i = 0; cmacs_brigade__privileged[i] != NULL; i++)
    if (strcmp (tool_name, cmacs_brigade__privileged[i]) == 0)
      return TRUE;
  return FALSE;
}

static gboolean
blocked_outright (const gchar *tool_name)
{
  gsize i;

  for (i = 0; cmacs_brigade__blocked_prefixes[i] != NULL; i++)
    if (g_str_has_prefix (tool_name, cmacs_brigade__blocked_prefixes[i]))
      return TRUE;
  return FALSE;
}

gboolean
cmacs_brigade_tool_allowed (const gchar *allowlist, const gchar *tool_name)
{
  g_auto (GStrv) entries = NULL;
  g_autofree gchar *group = NULL;
  gboolean privileged, saw_wildcard = FALSE;
  gsize i;

  /* Fail closed on anything malformed or empty. */
  if (tool_name == NULL || tool_name[0] == '\0') return FALSE;
  if (allowlist == NULL || allowlist[0] == '\0') return FALSE;
  if (blocked_outright (tool_name)) return FALSE;

  privileged = cmacs_brigade_tool_privileged (tool_name);

  /* Resolve the tool's group once, so a group grant can be matched
   * without holding the registry lock inside the scan loop. */
  {
    CmacsBrigadeTool *t = cmacs_brigade_registry_lookup (tool_name);
    if (t != NULL)
      {
        group = g_strdup (t->group);
        cmacs_brigade_tool_destroy (t);
      }
  }

  entries = g_strsplit (allowlist, ",", -1);
  for (i = 0; entries[i] != NULL; i++)
    {
      const gchar *e = g_strstrip (entries[i]);

      if (e[0] == '\0') continue;

      /* Exact name always wins, including for the privileged set --
       * that is the deliberate act the set exists to require. */
      if (strcmp (e, tool_name) == 0) return TRUE;

      if (strcmp (e, "*") == 0)
        {
          saw_wildcard = TRUE;
          continue;
        }

      /* Group grant.  Never unlocks a privileged tool: a group is a
       * convenience, and convenience must not be able to hand over
       * `eval' because some future tool was filed under the same
       * heading. */
      if (group != NULL && !privileged && strcmp (e, group) == 0)
        return TRUE;
    }

  return saw_wildcard && !privileged;
}

/* ── Expansion ────────────────────────────────────────────────────
 *
 * The relay runs in its own process and has no registry: it is spawned
 * by the AI CLI, not by cmacs, so nothing has ever called
 * `cmacs-brigade-deftool' there.  A group name therefore cannot be
 * resolved on that side, and an allowlist of "weather" would match
 * nothing at all -- silently, which is the worst way to fail.
 *
 * So groups are expanded here, in the process that owns the registry,
 * at the moment the agent's .mcp.json is written.  What reaches the
 * relay in CMACS_BRIGADE_ALLOW is always a concrete list of tool names,
 * and the relay only ever does exact matching plus the blocked-prefix
 * and privileged rules, which need no registry. */

struct expand_ctx
{
  const gchar *group;   /* the group being expanded */
  GString     *out;
  gboolean    *any;     /* set when the group matched something */
};

static void
expand_group (const CmacsBrigadeTool *tool, gpointer user_data)
{
  struct expand_ctx *ctx = user_data;

  if (tool->group == NULL || strcmp (tool->group, ctx->group) != 0) return;
  /* A group must not smuggle in a privileged tool -- same rule the
   * matcher applies, restated here because expansion bypasses it. */
  if (cmacs_brigade_tool_privileged (tool->name)) return;
  if (ctx->out->len > 0) g_string_append_c (ctx->out, ',');
  g_string_append (ctx->out, tool->name);
  *ctx->any = TRUE;
}

/* Resolve ALLOWLIST into a form the relay can evaluate without a
 * registry.  Returns a newly allocated string; free with g_free.
 *
 * Each entry is treated as follows:
 *
 *   "*"                 kept verbatim -- it means "every ordinary
 *                       tool", including cmacs's own built-in MCP
 *                       tools, which this registry has never heard of
 *   a known group name   expanded to the brigade tools in that group
 *   anything else        kept verbatim
 *
 * That last case is the important one.  The registry holds only tools
 * registered through `cmacs-brigade-deftool'; the bulk of what an agent
 * uses (project_read_file, memory_search, gowl_*, ...) is registered
 * directly on the MCP server in C and is invisible here.  Dropping
 * unrecognised names would therefore quietly strip an agent of almost
 * everything it was granted, so an unknown entry passes through and the
 * relay matches it by name against what the server actually offers. */
gchar *
cmacs_brigade_allowlist_expand (const gchar *allowlist)
{
  GString *out = g_string_new (NULL);
  g_auto (GStrv) entries = NULL;
  gsize i;

  if (allowlist == NULL || allowlist[0] == '\0')
    return g_string_free (out, FALSE);

  entries = g_strsplit (allowlist, ",", -1);
  for (i = 0; entries[i] != NULL; i++)
    {
      const gchar *e = g_strstrip (entries[i]);
      gboolean matched = FALSE;
      struct expand_ctx ctx;

      if (e[0] == '\0') continue;

      ctx.group = e;
      ctx.out   = out;
      ctx.any   = &matched;
      cmacs_brigade_registry_foreach (expand_group, &ctx);

      if (matched) continue;             /* it was a group */

      if (out->len > 0) g_string_append_c (out, ',');
      g_string_append (out, e);
    }

  return g_string_free (out, FALSE);
}

/* ── DEFUN ────────────────────────────────────────────────────────── */

DEFUN ("cmacs-brigade-tool-allowed-p", Fcmacs_brigade_tool_allowed_p,
       Scmacs_brigade_tool_allowed_p, 2, 2, 0,
       doc: /* Return t if ALLOWLIST authorises calling TOOL-NAME.

ALLOWLIST is a comma-separated string of tool names and/or group names.
The literal "*" grants every ordinary tool but never a privileged one
\(`eval', `bash', the C-patching tools and friends), which must be named
outright.  Tools whose names begin with "ai_" or "brigade_" are refused
unconditionally, so an agent cannot spawn agents outside the
orchestrator's budget accounting.

This is a read-only view of the C gate, exposed so configurations and
tests can ask what an agent would be permitted.  Answering nil here does
not merely predict a refusal: in-process agents are handed an executor
built from the tools that passed this test, so a refused tool is absent
rather than rejected.  */)
  (Lisp_Object allowlist, Lisp_Object tool_name)
{
  CHECK_STRING (tool_name);
  if (NILP (allowlist)) return Qnil;
  CHECK_STRING (allowlist);
  return cmacs_brigade_tool_allowed (SSDATA (allowlist), SSDATA (tool_name))
    ? Qt : Qnil;
}

DEFUN ("cmacs-brigade-allowlist-expand", Fcmacs_brigade_allowlist_expand,
       Scmacs_brigade_allowlist_expand, 1, 1, 0,
       doc: /* Resolve group names in ALLOWLIST to concrete tool names.

Returns a comma-separated string suitable for CMACS_BRIGADE_ALLOW in a
spawned agent's environment.  Group names expand to the brigade tools in
that group; "*" and any name the registry does not recognise pass
through untouched, the latter because most of what an agent uses is a
built-in MCP tool this registry has never seen.

Expansion happens here rather than in the relay because the relay runs
in its own process with an empty registry -- a group name would resolve
to nothing there, and would do so silently.  */)
  (Lisp_Object allowlist)
{
  g_autofree gchar *expanded = NULL;

  if (NILP (allowlist)) return build_string ("");
  CHECK_STRING (allowlist);
  expanded = cmacs_brigade_allowlist_expand (SSDATA (allowlist));
  return build_string (expanded ? expanded : "");
}

DEFUN ("cmacs-brigade-tool-privileged-p", Fcmacs_brigade_tool_privileged_p,
       Scmacs_brigade_tool_privileged_p, 1, 1, 0,
       doc: /* Return t if TOOL-NAME is in the privileged set.

Privileged tools are denied unless an allowlist names them explicitly --
a "*" or a group grant never reaches them.  */)
  (Lisp_Object tool_name)
{
  CHECK_STRING (tool_name);
  return cmacs_brigade_tool_privileged (SSDATA (tool_name)) ? Qt : Qnil;
}

void syms_of_cmacs_ai_brigade_allowlist (void);
void
syms_of_cmacs_ai_brigade_allowlist (void)
{
  defsubr (&Scmacs_brigade_tool_allowed_p);
  defsubr (&Scmacs_brigade_allowlist_expand);
  defsubr (&Scmacs_brigade_tool_privileged_p);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
