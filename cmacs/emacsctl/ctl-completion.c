/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-completion.c --- see ctl-completion.h.
 *
 * kubectl model: the shell scripts are static and delegate every
 * completion to the binary itself (`__complete -- words...`), so
 * dynamic candidates (buffer names, instance pids, context names)
 * come straight from the live editor/config. */

#include "ctl-completion.h"
#include "ctl-config.h"

#include <stdio.h>
#include <string.h>

static const gchar *bash_script =
  "# emacsctl bash completion --- eval \"$(emacsctl completion bash)\"\n"
  "_emacsctl_complete()\n"
  "{\n"
  "  local cur words\n"
  "  cur=\"${COMP_WORDS[COMP_CWORD]}\"\n"
  "  words=(\"${COMP_WORDS[@]:1:COMP_CWORD}\")\n"
  "  COMPREPLY=($(\"${COMP_WORDS[0]}\" __complete -- \"${words[@]}\" "
  "2>/dev/null))\n"
  "}\n"
  "complete -F _emacsctl_complete emacsctl cmacsctl\n";

static const gchar *zsh_script =
  "# emacsctl zsh completion --- eval \"$(emacsctl completion zsh)\"\n"
  "_emacsctl_complete()\n"
  "{\n"
  "  local -a candidates\n"
  "  candidates=($(${words[1]} __complete -- ${words[2,CURRENT]} "
  "2>/dev/null))\n"
  "  compadd -a candidates\n"
  "}\n"
  "compdef _emacsctl_complete emacsctl cmacsctl\n";

gint
ctl_completion_print_script (const gchar *shell, GError **error)
{
  if (g_strcmp0 (shell, "bash") == 0)
    {
      fputs (bash_script, stdout);
      return CTL_EXIT_OK;
    }
  if (g_strcmp0 (shell, "zsh") == 0)
    {
      fputs (zsh_script, stdout);
      return CTL_EXIT_OK;
    }
  g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
               "unsupported shell '%s' (expected bash or zsh)",
               shell != NULL ? shell : "");
  return CTL_EXIT_USAGE;
}

static void
emit_if_prefix (const gchar *candidate, const gchar *prefix)
{
  if (prefix == NULL || g_str_has_prefix (candidate, prefix))
    printf ("%s\n", candidate);
}

gint
ctl_completion_complete (CtlCommandRegistry *registry,
                         CtlInvocation *inv)
{
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  const gchar *prefix = argc > 0 ? argv[argc - 1] : "";
  gint done = argc > 0 ? argc - 1 : 0;   /* completed words */
  guint n = ctl_command_registry_get_n_commands (registry);
  guint k;

  /* Word 0/1: complete command paths. */
  if (done <= 1)
    {
      GHashTable *seen = g_hash_table_new_full (g_str_hash, g_str_equal,
                                                g_free, NULL);
      for (k = 0; k < n; k++)
        {
          CtlCommand *cmd = ctl_command_registry_get_nth (registry, k);
          const gchar *name = ctl_command_get_name (cmd);
          const gchar *space = strchr (name, ' ');

          if (name[0] == '_')
            continue;
          if (done == 0)
            {
              /* First word: group names (or bare verbs). */
              gchar *head = space != NULL
                ? g_strndup (name, space - name) : g_strdup (name);
              if (!g_hash_table_contains (seen, head))
                {
                  emit_if_prefix (head, prefix);
                  g_hash_table_insert (seen, head, GINT_TO_POINTER (1));
                }
              else
                g_free (head);
            }
          else if (space != NULL
                   && strncmp (name, argv[0], space - name) == 0
                   && argv[0][space - name] == '\0')
            emit_if_prefix (space + 1, prefix);
        }
      g_hash_table_unref (seen);
      if (done == 1)
        {
          /* argv[0] may itself be a complete bare command; nothing
           * more to add. */
        }
      return CTL_EXIT_OK;
    }

  /* Deeper: ask the command itself. */
  {
    gint consumed = 0;
    CtlCommand *cmd = ctl_command_registry_lookup (registry, argv,
                                                   argc, &consumed);
    if (cmd != NULL)
      {
        gchar **candidates = ctl_command_complete (
          cmd, inv, done - consumed, prefix);
        if (candidates != NULL)
          {
            for (k = 0; candidates[k] != NULL; k++)
              emit_if_prefix (candidates[k], prefix);
            g_strfreev (candidates);
          }
      }
  }
  return CTL_EXIT_OK;
}
