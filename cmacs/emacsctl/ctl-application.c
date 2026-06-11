/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-application.c --- see ctl-application.h. */

#include "ctl-application.h"
#include "ctl-config.h"
#include "ctl-invocation.h"

#include <stdio.h>
#include <string.h>

struct _CtlApplication
{
  GObject parent_instance;
  CtlCommandRegistry *registry;
};

G_DEFINE_FINAL_TYPE (CtlApplication, ctl_application, G_TYPE_OBJECT)

static void
ctl_application_finalize (GObject *object)
{
  CtlApplication *self = CTL_APPLICATION (object);
  g_clear_object (&self->registry);
  G_OBJECT_CLASS (ctl_application_parent_class)->finalize (object);
}

static void
ctl_application_class_init (CtlApplicationClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_application_finalize;
}

static void
ctl_application_init (CtlApplication *self)
{
  self->registry = ctl_command_registry_new ();
}

CtlApplication *
ctl_application_new (void)
{
  return g_object_new (CTL_TYPE_APPLICATION, NULL);
}

CtlCommandRegistry *
ctl_application_get_registry (CtlApplication *self)
{
  return self->registry;
}

/* ── Help output ───────────────────────────────────────────────────── */

/* Hidden commands (the __complete backend, the proxy bridge) never
 * appear in help or suggestions. */
static gboolean
command_hidden_p (const gchar *name)
{
  return name[0] == '_' || g_strcmp0 (name, "proxy") == 0;
}

/* The global flags, declared once.  ctl_application_run parses them
 * against per-run storage; the help renderers display them through a
 * "Global Options" GOptionGroup whose arg_data targets this static
 * dummy storage (display only --- never parsed through it). */
typedef struct
{
  gchar *context;
  gchar *instance;
  gchar *host;
  gchar *output;
  gboolean watch;
  gint timeout;
  gchar *config;
  gboolean quiet;
  gboolean version;
} CtlGlobalOptions;

static void
fill_global_entries (GOptionEntry *entries, CtlGlobalOptions *opts)
{
  static const GOptionEntry template_entries[] = {
    { "context", 'c', 0, G_OPTION_ARG_STRING, NULL,
      "Use a named context from the config file", "NAME" },
    { "instance", 0, 0, G_OPTION_ARG_STRING, NULL,
      "Target instance: <pid>, primary, or auto (newest)", "SEL" },
    { "host", 0, 0, G_OPTION_ARG_STRING, NULL,
      "Remote editor over ssh (user@machine)", "DEST" },
    { "output", 'o', 0, G_OPTION_ARG_STRING, NULL,
      "Output format: table, json, yaml, or raw", "FMT" },
    { "watch", 'w', 0, G_OPTION_ARG_NONE, NULL,
      "Stream changes where supported", NULL },
    { "timeout", 0, 0, G_OPTION_ARG_INT, NULL,
      "RPC timeout in seconds (default 30)", "SECS" },
    { "config", 0, 0, G_OPTION_ARG_STRING, NULL,
      "Config file (default ~/.config/cmacs/emacsctl.yaml)", "PATH" },
    { "quiet", 'q', 0, G_OPTION_ARG_NONE, NULL,
      "Suppress non-essential output", NULL },
    { "version", 0, 0, G_OPTION_ARG_NONE, NULL,
      "Print the client version", NULL },
    { NULL, 0, 0, 0, NULL, NULL, NULL }
  };

  memcpy (entries, template_entries, sizeof template_entries);
  entries[0].arg_data = &opts->context;
  entries[1].arg_data = &opts->instance;
  entries[2].arg_data = &opts->host;
  entries[3].arg_data = &opts->output;
  entries[4].arg_data = &opts->watch;
  entries[5].arg_data = &opts->timeout;
  entries[6].arg_data = &opts->config;
  entries[7].arg_data = &opts->quiet;
  entries[8].arg_data = &opts->version;
}

#define CTL_N_GLOBAL_ENTRIES 10   /* incl. NULL terminator */

/* A display-only "Global Options" group for per-command help.  Its
 * arg_data points at static dummies; the group is never parsed. */
static GOptionGroup *
global_help_group (void)
{
  static CtlGlobalOptions dummies;
  static GOptionEntry entries[CTL_N_GLOBAL_ENTRIES];
  GOptionGroup *group;

  fill_global_entries (entries, &dummies);
  group = g_option_group_new ("global", "Global Options:",
                              "Show global options", NULL, NULL);
  g_option_group_add_entries (group, entries);
  return group;
}

/* GOption-rendered help for one command, with its flags (if any) and
 * the global options group.  Caller g_frees. */
static gchar *
command_help_string (CtlCommand *cmd, const gchar *prog)
{
  const gchar *usage = ctl_command_get_usage (cmd);
  const GOptionEntry *entries = ctl_command_get_option_entries (cmd);
  GOptionContext *ctx;
  gchar *qualified, *help;
  const gchar *saved_prgname = g_get_prgname ();
  gchar *saved = g_strdup (saved_prgname != NULL ? saved_prgname : "");

  /* The usage line reads "Usage: <prgname> [OPTION…] <usage>". */
  qualified = g_strdup_printf ("%s %s", prog,
                               ctl_command_get_name (cmd));
  g_set_prgname (qualified);

  ctx = g_option_context_new (usage != NULL && *usage != '\0'
                              ? usage : NULL);
  g_option_context_set_summary (ctx, ctl_command_get_summary (cmd));
  if (entries != NULL)
    g_option_context_add_main_entries (ctx, entries, NULL);
  g_option_context_add_group (ctx, global_help_group ());

  help = g_option_context_get_help (ctx, FALSE, NULL);
  g_option_context_free (ctx);
  g_set_prgname (saved);
  g_free (saved);
  g_free (qualified);
  return help;
}

/* Does GROUP prefix at least one visible command ("get" -> "get …")? */
static gboolean
group_exists (CtlApplication *self, const gchar *group)
{
  guint n = ctl_command_registry_get_n_commands (self->registry);
  guint k;
  gsize len = strlen (group);

  for (k = 0; k < n; k++)
    {
      const gchar *name = ctl_command_get_name (
        ctl_command_registry_get_nth (self->registry, k));
      if (!command_hidden_p (name)
          && strncmp (name, group, len) == 0 && name[len] == ' ')
        return TRUE;
    }
  return FALSE;
}

/* The visible commands of GROUP, sorted by name.  Caller frees the
 * array (the commands are owned by the registry). */
static gint
compare_command_names (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (ctl_command_get_name (*(CtlCommand **) a),
                    ctl_command_get_name (*(CtlCommand **) b));
}

static GPtrArray *
group_commands_sorted (CtlApplication *self, const gchar *group)
{
  GPtrArray *out = g_ptr_array_new ();
  guint n = ctl_command_registry_get_n_commands (self->registry);
  guint k;
  gsize len = strlen (group);

  for (k = 0; k < n; k++)
    {
      CtlCommand *cmd = ctl_command_registry_get_nth (self->registry, k);
      const gchar *name = ctl_command_get_name (cmd);
      if (!command_hidden_p (name)
          && strncmp (name, group, len) == 0 && name[len] == ' ')
        g_ptr_array_add (out, cmd);
    }
  g_ptr_array_sort (out, compare_command_names);
  return out;
}

/* Help for a command group: every verb with usage and summary.
 * Caller g_frees. */
static gchar *
group_help_string (CtlApplication *self, const gchar *prog,
                   const gchar *group)
{
  GString *out = g_string_new (NULL);
  GPtrArray *cmds = group_commands_sorted (self, group);
  guint k;
  gsize len = strlen (group);

  g_string_append_printf (out,
    "Usage:\n  %s [OPTION…] %s SUBCOMMAND [ARGS…]\n\n", prog, group);
  g_string_append_printf (out, "Subcommands of '%s':\n", group);

  for (k = 0; k < cmds->len; k++)
    {
      CtlCommand *cmd = g_ptr_array_index (cmds, k);
      const gchar *name = ctl_command_get_name (cmd);
      const gchar *usage = ctl_command_get_usage (cmd);
      const gchar *summary = ctl_command_get_summary (cmd);
      gchar *label;

      label = (usage != NULL && *usage != '\0')
        ? g_strdup_printf ("%s %s", name + len + 1, usage)
        : g_strdup (name + len + 1);
      if (strlen (label) > 30)
        g_string_append_printf (out, "  %s\n  %-30s   %s\n", label, "",
                                summary != NULL ? summary : "");
      else
        g_string_append_printf (out, "  %-30s   %s\n", label,
                                summary != NULL ? summary : "");
      g_free (label);
    }
  g_ptr_array_free (cmds, TRUE);

  g_string_append_printf (out,
    "\nRun '%s %s SUBCOMMAND --help' for details on one subcommand,\n"
    "and '%s --help' for the global options.\n", prog, group, prog);
  return g_string_free (out, FALSE);
}

/* Top-level help: GOption-rendered global options, with a generated
 * command overview as the summary.  Caller g_frees. */
static gchar *
global_help_string (CtlApplication *self, const gchar *prog)
{
  GString *summary = g_string_new (
    "kubectl-style CLI for a running cmacs/emacs instance\n"
    "(installed as both emacsctl and cmacsctl).\n\n");
  guint n = ctl_command_registry_get_n_commands (self->registry);
  guint k;
  GHashTable *seen_groups;
  GOptionContext *ctx;
  GOptionEntry entries[CTL_N_GLOBAL_ENTRIES];
  static CtlGlobalOptions dummies;
  gchar *help;
  const gchar *saved_prgname = g_get_prgname ();
  gchar *saved = g_strdup (saved_prgname != NULL ? saved_prgname : "");

  /* Bare commands first... */
  g_string_append (summary, "Commands:\n");
  for (k = 0; k < n; k++)
    {
      CtlCommand *cmd = ctl_command_registry_get_nth (self->registry, k);
      const gchar *name = ctl_command_get_name (cmd);
      const gchar *summary_text = ctl_command_get_summary (cmd);
      if (command_hidden_p (name) || strchr (name, ' ') != NULL)
        continue;
      g_string_append_printf (summary, "  %-14s %s\n", name,
                              summary_text != NULL ? summary_text : "");
    }

  /* ...then groups, with their verbs wrapped compactly. */
  g_string_append (summary,
    "\nCommand groups (run '");
  g_string_append (summary, prog);
  g_string_append (summary, " GROUP --help' for details):\n");

  seen_groups = g_hash_table_new_full (g_str_hash, g_str_equal,
                                       g_free, NULL);
  for (k = 0; k < n; k++)
    {
      const gchar *name = ctl_command_get_name (
        ctl_command_registry_get_nth (self->registry, k));
      const gchar *space = strchr (name, ' ');
      gchar *group;
      guint j;
      gsize col;

      if (command_hidden_p (name) || space == NULL)
        continue;
      group = g_strndup (name, space - name);
      if (g_hash_table_contains (seen_groups, group))
        {
          g_free (group);
          continue;
        }
      g_hash_table_insert (seen_groups, group, GINT_TO_POINTER (1));

      g_string_append_printf (summary, "  %-12s", group);
      col = 14;
      {
        GPtrArray *members = group_commands_sorted (self, group);
        gsize glen = strlen (group);
        for (j = 0; j < members->len; j++)
          {
            const gchar *verb = ctl_command_get_name (
              g_ptr_array_index (members, j)) + glen + 1;
            if (col + strlen (verb) + 1 > 76)
              {
                g_string_append (summary, "\n              ");
                col = 14;
              }
            g_string_append_printf (summary, " %s", verb);
            col += strlen (verb) + 1;
          }
        g_ptr_array_free (members, TRUE);
      }
      g_string_append_c (summary, '\n');
    }
  g_hash_table_unref (seen_groups);
  /* Trim the trailing newline: GOption adds spacing after summaries. */
  if (summary->len > 0 && summary->str[summary->len - 1] == '\n')
    g_string_truncate (summary, summary->len - 1);

  g_set_prgname (prog);
  ctx = g_option_context_new ("COMMAND [ARGS…]");
  g_option_context_set_summary (ctx, summary->str);
  g_option_context_set_description (ctx,
    "Examples:\n"
    "  emacsctl instances\n"
    "  emacsctl eval '(emacs-version)'\n"
    "  emacsctl get buffers -o json\n"
    "  emacsctl repl --lang crispy\n"
    "  emacsctl logs -f\n"
    "  emacsctl --host user@machine get buffers\n\n"
    "Run 'emacsctl COMMAND --help' (or 'emacsctl help COMMAND') for\n"
    "per-command options.\n");
  fill_global_entries (entries, &dummies);
  g_option_context_add_main_entries (ctx, entries, NULL);

  help = g_option_context_get_help (ctx, FALSE, NULL);
  g_option_context_free (ctx);
  g_set_prgname (saved);
  g_free (saved);
  g_string_free (summary, TRUE);
  return help;
}

/* Resolve a help request for WORDS (already stripped of help flags):
 * a full command, a group, or the global overview.  Returns an exit
 * code; prints to stdout. */
static gint
print_help_for (CtlApplication *self, const gchar *prog,
                gchar **words, gint n_words)
{
  gchar *help = NULL;

  if (n_words == 0)
    help = global_help_string (self, prog);
  else
    {
      gint consumed = 0;
      CtlCommand *cmd = ctl_command_registry_lookup (
        self->registry, words, n_words, &consumed);
      if (cmd != NULL && !command_hidden_p (ctl_command_get_name (cmd)))
        help = command_help_string (cmd, prog);
      else if (group_exists (self, words[0]))
        help = group_help_string (self, prog, words[0]);
    }

  if (help == NULL)
    {
      fprintf (stderr, "%s: no help for '%s' (try '%s --help')\n",
               prog, n_words > 0 ? words[0] : "", prog);
      return CTL_EXIT_USAGE;
    }
  fputs (help, stdout);
  g_free (help);
  return CTL_EXIT_OK;
}

/* ── Per-command option parsing ────────────────────────────────────── */

/* Parse CMD's flags out of ARGV (in place) with a GOptionContext
 * built from its option entries.  Commands without entries parse
 * with ignore-unknown so dash-prefixed positionals survive. */
static gboolean
parse_command_options (CtlCommand *cmd, const gchar *prog,
                       gchar **argv, gint *argc, GError **error)
{
  const GOptionEntry *entries = ctl_command_get_option_entries (cmd);
  GOptionContext *ctx;
  gchar **parse_argv;
  gint parse_argc;
  gint k;
  gboolean ok;

  ctx = g_option_context_new (NULL);
  g_option_context_set_help_enabled (ctx, FALSE);
  if (entries != NULL)
    g_option_context_add_main_entries (ctx, entries, NULL);
  else
    g_option_context_set_ignore_unknown_options (ctx, TRUE);

  /* g_option_context_parse skips argv[0] (the program name). */
  parse_argc = *argc + 1;
  parse_argv = g_new0 (gchar *, parse_argc + 1);
  parse_argv[0] = g_strdup (prog);
  for (k = 0; k < *argc; k++)
    parse_argv[k + 1] = g_strdup (argv[k]);

  ok = g_option_context_parse (ctx, &parse_argc, &parse_argv, error);
  g_option_context_free (ctx);
  if (!ok)
    {
      g_strfreev (parse_argv);
      return FALSE;
    }

  /* Copy the surviving positionals back. */
  for (k = 0; k < *argc; k++)
    g_free (argv[k]);
  for (k = 1; k < parse_argc; k++)
    argv[k - 1] = g_strdup (parse_argv[k]);
  for (k = parse_argc - 1; k < *argc; k++)
    argv[k] = NULL;
  *argc = parse_argc - 1;
  g_strfreev (parse_argv);
  return TRUE;
}

/* ── Did-you-mean suggestions ──────────────────────────────────────── */

/* Bounded Levenshtein distance (good enough for typo suggestions). */
static gint
edit_distance (const gchar *a, const gchar *b)
{
  gsize la = strlen (a), lb = strlen (b);
  gint *prev, *curr, *tmp;
  gsize i, j;
  gint result;

  prev = g_new0 (gint, lb + 1);
  curr = g_new0 (gint, lb + 1);
  for (j = 0; j <= lb; j++)
    prev[j] = (gint) j;
  for (i = 1; i <= la; i++)
    {
      curr[0] = (gint) i;
      for (j = 1; j <= lb; j++)
        {
          gint cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
          gint del = prev[j] + 1;
          gint ins = curr[j - 1] + 1;
          gint sub = prev[j - 1] + cost;
          curr[j] = MIN (MIN (del, ins), sub);
        }
      tmp = prev; prev = curr; curr = tmp;
    }
  result = prev[lb];
  g_free (prev);
  g_free (curr);
  return result;
}

/* Closest registered command name to ATTEMPTED, or NULL when nothing
 * is plausibly a typo.  Caller g_frees. */
static gchar *
suggest_command (CtlApplication *self, const gchar *attempted)
{
  guint n = ctl_command_registry_get_n_commands (self->registry);
  guint k;
  const gchar *best = NULL;
  gint best_distance = G_MAXINT;

  for (k = 0; k < n; k++)
    {
      CtlCommand *cmd = ctl_command_registry_get_nth (self->registry, k);
      const gchar *name = ctl_command_get_name (cmd);
      gint distance;

      if (name[0] == '_')       /* hidden */
        continue;
      distance = edit_distance (attempted, name);
      if (distance < best_distance)
        {
          best_distance = distance;
          best = name;
        }
    }

  /* Accept only close matches, scaled a little by length. */
  if (best != NULL
      && best_distance <= MAX (2, (gint) strlen (attempted) / 4))
    return g_strdup (best);
  return NULL;
}

/* ── Run ───────────────────────────────────────────────────────────── */

gint
ctl_application_run (CtlApplication *self, gint argc, gchar **argv)
{
  CtlGlobalOptions opt = { NULL, NULL, NULL, NULL, FALSE, 0, NULL,
                           FALSE, FALSE };
  GOptionEntry entries[CTL_N_GLOBAL_ENTRIES];
  GOptionContext *opts;
  GError *error = NULL;
  gchar *prog;
  gint code = CTL_EXIT_OK;
  CtlConfig *config = NULL;
  CtlContext *context = NULL;
  CtlInvocation *inv = NULL;

  fill_global_entries (entries, &opt);
  prog = g_path_get_basename (argv[0]);

  opts = g_option_context_new ("COMMAND [ARGS…]");
  g_option_context_add_main_entries (opts, entries, NULL);
  /* --help is resolved contextually below (global vs group vs
   * command), so GOption must not eat it here; per-command flags
   * (logs -n, eval --lang, ...) pass through to the second-pass
   * parse against the command's own option entries. */
  g_option_context_set_help_enabled (opts, FALSE);
  g_option_context_set_ignore_unknown_options (opts, TRUE);

  if (!g_option_context_parse (opts, &argc, &argv, &error))
    {
      fprintf (stderr, "%s: %s\n", prog, error->message);
      g_error_free (error);
      code = CTL_EXIT_USAGE;
      goto out;
    }

  if (opt.version)
    {
      printf ("%s %s\n", prog, CTL_VERSION);
      goto out;
    }

  if (argc < 2)
    {
      gchar *help = global_help_string (self, prog);
      fputs (help, stdout);
      g_free (help);
      goto out;
    }

  /* Config + context resolution: flags > context > config defaults. */
  config = ctl_config_load (opt.config, &error);
  if (config == NULL)
    {
      fprintf (stderr, "%s: %s\n", prog, error->message);
      g_error_free (error);
      code = CTL_EXIT_USAGE;
      goto out;
    }
  context = ctl_config_resolve_context (config, opt.context, &error);
  if (context == NULL)
    {
      fprintf (stderr, "%s: %s\n", prog, error->message);
      g_error_free (error);
      code = CTL_EXIT_USAGE;
      goto out;
    }

  inv = ctl_invocation_new ();
  ctl_invocation_set_config (inv, config);
  ctl_invocation_set_instance (inv,
    opt.instance != NULL ? opt.instance : context->instance);
  ctl_invocation_set_host (inv,
    opt.host != NULL ? opt.host : context->host);
  ctl_invocation_set_output (inv,
    opt.output != NULL ? opt.output
    : (context->output != NULL ? context->output : "table"));
  ctl_invocation_set_watch (inv, opt.watch);
  if (opt.timeout > 0)
    ctl_invocation_set_timeout (inv, opt.timeout);
  else if (context->timeout > 0)
    ctl_invocation_set_timeout (inv, context->timeout);
  else if (ctl_config_get_timeout (config) > 0)
    ctl_invocation_set_timeout (inv, ctl_config_get_timeout (config));

  /* Alias expansion on the first word. */
  {
    gchar *alias = ctl_config_expand_alias (config, argv[1]);
    gchar **cmd_argv;
    gint cmd_argc;

    if (alias != NULL)
      {
        gchar **alias_words = g_strsplit (alias, " ", -1);
        gint n_alias = g_strv_length (alias_words);
        gint rest = argc - 2;
        gint k;

        cmd_argc = n_alias + rest;
        cmd_argv = g_new0 (gchar *, cmd_argc + 1);
        for (k = 0; k < n_alias; k++)
          cmd_argv[k] = g_strdup (alias_words[k]);
        for (k = 0; k < rest; k++)
          cmd_argv[n_alias + k] = g_strdup (argv[2 + k]);
        g_strfreev (alias_words);
        g_free (alias);
      }
    else
      {
        gint k;
        cmd_argc = argc - 1;
        cmd_argv = g_new0 (gchar *, cmd_argc + 1);
        for (k = 0; k < cmd_argc; k++)
          cmd_argv[k] = g_strdup (argv[1 + k]);
      }

    /* Contextual help: `help [WORDS…]', or --help/-h anywhere before
     * a `--` terminator, resolves against the words typed so far
     * (command > group > global). */
    {
      gboolean help_requested = FALSE;
      gint k, w = 0;

      if (cmd_argc > 0 && g_strcmp0 (cmd_argv[0], "help") == 0)
        {
          help_requested = TRUE;
          g_free (cmd_argv[0]);
          for (k = 1; k <= cmd_argc; k++)
            cmd_argv[k - 1] = cmd_argv[k];
          cmd_argc--;
        }
      for (k = 0; k < cmd_argc; k++)
        {
          if (g_strcmp0 (cmd_argv[k], "--") == 0)
            break;
          if (g_strcmp0 (cmd_argv[k], "--help") == 0
              || g_strcmp0 (cmd_argv[k], "-h") == 0)
            {
              gint j;
              help_requested = TRUE;
              g_free (cmd_argv[k]);
              for (j = k + 1; j <= cmd_argc; j++)
                cmd_argv[j - 1] = cmd_argv[j];
              cmd_argc--;
              k--;
            }
        }
      (void) w;

      if (help_requested)
        {
          code = print_help_for (self, prog, cmd_argv, cmd_argc);
          g_strfreev (cmd_argv);
          goto out;
        }
    }

    {
      gint consumed = 0;
      CtlCommand *cmd = ctl_command_registry_lookup (
        self->registry, cmd_argv, cmd_argc, &consumed);

      if (cmd == NULL)
        {
          /* Blame the full attempted command, not just the group:
           * `get nuffers' should not report "unknown command 'get'". */
          gboolean is_group = group_exists (self, cmd_argv[0]);
          gchar *attempted = cmd_argc >= 2
            ? g_strdup_printf ("%s %s", cmd_argv[0], cmd_argv[1])
            : g_strdup (cmd_argv[0]);
          gchar *suggestion = suggest_command (self, attempted);

          if (is_group && cmd_argc >= 2)
            fprintf (stderr, "%s: unknown subcommand '%s' for '%s'\n",
                     prog, cmd_argv[1], cmd_argv[0]);
          else if (!is_group)
            fprintf (stderr, "%s: unknown command '%s'\n", prog,
                     attempted);

          if (suggestion != NULL)
            fprintf (stderr, "Did you mean '%s %s'?\n", prog,
                     suggestion);
          else if (is_group)
            {
              /* A bare group (or hopeless typo): show its verbs. */
              gchar *help = group_help_string (self, prog, cmd_argv[0]);
              if (cmd_argc >= 2)
                fputc ('\n', stderr);
              fputs (help, stderr);
              g_free (help);
            }
          else
            fprintf (stderr, "Run '%s help' for the command list.\n",
                     prog);
          g_free (attempted);
          g_free (suggestion);
          g_strfreev (cmd_argv);
          code = CTL_EXIT_USAGE;
          goto out;
        }

      /* Second pass: the command's own flags, declared as
       * GOptionEntry arrays.  Hidden commands (__complete, proxy)
       * receive their argv verbatim. */
      if (!command_hidden_p (ctl_command_get_name (cmd)))
        {
          gint rest = cmd_argc - consumed;
          if (!parse_command_options (cmd, prog, cmd_argv + consumed,
                                      &rest, &error))
            {
              fprintf (stderr, "%s: %s\n", prog, error->message);
              fprintf (stderr, "See '%s %s --help'.\n", prog,
                       ctl_command_get_name (cmd));
              g_error_free (error);
              g_strfreev (cmd_argv);
              code = CTL_EXIT_USAGE;
              goto out;
            }
          ctl_invocation_set_args (inv, cmd_argv + consumed, rest);
        }
      else
        ctl_invocation_set_args (inv, cmd_argv + consumed,
                                 cmd_argc - consumed);
      g_strfreev (cmd_argv);

      code = ctl_command_run (cmd, inv, &error);
      if (error != NULL)
        {
          gchar *remote = g_dbus_error_get_remote_error (error);
          if (remote != NULL
              && (strstr (remote, "UnknownInterface") != NULL
                  || strstr (remote, "UnknownMethod") != NULL))
            fprintf (stderr,
                     "%s: this cmacs does not provide the required "
                     "interface (server too old or subsystem not "
                     "compiled in)\n", prog);
          else
            {
              g_dbus_error_strip_remote_error (error);
              fprintf (stderr, "%s: %s\n", prog, error->message);
            }
          if (code == CTL_EXIT_OK)
            code = ctl_exit_code_for_error (error);
          g_free (remote);
          g_error_free (error);
        }
    }
  }

out:
  if (inv != NULL)
    ctl_invocation_unref (inv);
  if (context != NULL)
    ctl_context_free (context);
  if (config != NULL)
    g_object_unref (config);
  g_option_context_free (opts);
  g_free (prog);
  g_free (opt.context);
  g_free (opt.instance);
  g_free (opt.host);
  g_free (opt.output);
  g_free (opt.config);
  return code;
}
