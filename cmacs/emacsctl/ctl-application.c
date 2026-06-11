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

static void
print_help (CtlApplication *self, const gchar *prog)
{
  guint n = ctl_command_registry_get_n_commands (self->registry);
  guint k;
  gchar *last_group = NULL;

  printf ("usage: %s [global flags] <command> [args]   "
          "(also invocable as emacsctl or cmacsctl)\n\n", prog);
  printf ("kubectl-style CLI for a running cmacs/emacs instance.\n\n");
  printf ("Global flags:\n"
          "  -c, --context NAME    use a named context from the config\n"
          "      --instance SEL    target instance: <pid>|primary|auto\n"
          "      --host DEST       remote editor over ssh "
          "(user@machine)\n"
          "  -o, --output FMT      table|json|yaml|raw\n"
          "  -w, --watch           stream changes (where supported)\n"
          "      --timeout SECS    RPC timeout (default 30)\n"
          "      --config PATH     config file "
          "(default ~/.config/cmacs/emacsctl.yaml)\n"
          "  -q, --quiet           suppress non-essential output\n"
          "      --version         print client version\n\n");
  printf ("Commands:\n");

  for (k = 0; k < n; k++)
    {
      CtlCommand *cmd = ctl_command_registry_get_nth (self->registry, k);
      const gchar *name = ctl_command_get_name (cmd);
      const gchar *summary = ctl_command_get_summary (cmd);
      const gchar *space = strchr (name, ' ');
      gchar *group = space != NULL
        ? g_strndup (name, space - name) : g_strdup ("");

      if (name[0] == '_')       /* hidden (__complete, proxy) */
        {
          g_free (group);
          continue;
        }
      if (g_strcmp0 (group, last_group) != 0)
        printf ("\n");
      g_free (last_group);
      last_group = group;
      printf ("  %-28s %s\n", name, summary != NULL ? summary : "");
    }
  g_free (last_group);
  printf ("\nRun '%s <command> --help' style usage via "
          "'%s help <command>'.\n", prog, prog);
}

static gint
print_command_help (CtlApplication *self, const gchar *prog,
                    gchar **argv, gint argc)
{
  gint consumed = 0;
  CtlCommand *cmd =
    ctl_command_registry_lookup (self->registry, argv, argc, &consumed);
  if (cmd == NULL)
    {
      fprintf (stderr, "%s: unknown command '%s'\n", prog,
               argc > 0 ? argv[0] : "");
      return CTL_EXIT_USAGE;
    }
  printf ("usage: %s %s %s\n\n  %s\n",
          prog, ctl_command_get_name (cmd),
          ctl_command_get_usage (cmd) != NULL
          ? ctl_command_get_usage (cmd) : "",
          ctl_command_get_summary (cmd) != NULL
          ? ctl_command_get_summary (cmd) : "");
  return CTL_EXIT_OK;
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
  gchar *opt_context = NULL, *opt_instance = NULL, *opt_host = NULL;
  gchar *opt_output = NULL, *opt_config = NULL;
  gboolean opt_watch = FALSE, opt_quiet = FALSE, opt_version = FALSE;
  gint opt_timeout = 0;
  GOptionContext *opts;
  GError *error = NULL;
  gchar *prog;
  gint code = CTL_EXIT_OK;
  CtlConfig *config = NULL;
  CtlContext *context = NULL;
  CtlInvocation *inv = NULL;

  GOptionEntry entries[] = {
    { "context", 'c', 0, G_OPTION_ARG_STRING, NULL, "Named context",
      "NAME" },
    { "instance", 0, 0, G_OPTION_ARG_STRING, NULL,
      "Instance selector: <pid>|primary|auto", "SEL" },
    { "host", 0, 0, G_OPTION_ARG_STRING, NULL,
      "Remote editor over ssh", "DEST" },
    { "output", 'o', 0, G_OPTION_ARG_STRING, NULL,
      "table|json|yaml|raw", "FMT" },
    { "watch", 'w', 0, G_OPTION_ARG_NONE, NULL,
      "Stream changes", NULL },
    { "timeout", 0, 0, G_OPTION_ARG_INT, NULL,
      "RPC timeout seconds", "SECS" },
    { "config", 0, 0, G_OPTION_ARG_STRING, NULL,
      "Config file path", "PATH" },
    { "quiet", 'q', 0, G_OPTION_ARG_NONE, NULL,
      "Suppress non-essential output", NULL },
    { "version", 0, 0, G_OPTION_ARG_NONE, NULL,
      "Print client version", NULL },
    { NULL, 0, 0, 0, NULL, NULL, NULL }
  };

  entries[0].arg_data = &opt_context;
  entries[1].arg_data = &opt_instance;
  entries[2].arg_data = &opt_host;
  entries[3].arg_data = &opt_output;
  entries[4].arg_data = &opt_watch;
  entries[5].arg_data = &opt_timeout;
  entries[6].arg_data = &opt_config;
  entries[7].arg_data = &opt_quiet;
  entries[8].arg_data = &opt_version;

  prog = g_path_get_basename (argv[0]);

  opts = g_option_context_new ("<command> [args]");
  g_option_context_add_main_entries (opts, entries, NULL);
  g_option_context_set_help_enabled (opts, FALSE);
  /* Per-command flags (logs -n, eval --lang, ...) pass through to the
   * command's own argv. */
  g_option_context_set_ignore_unknown_options (opts, TRUE);

  if (!g_option_context_parse (opts, &argc, &argv, &error))
    {
      fprintf (stderr, "%s: %s\n", prog, error->message);
      g_error_free (error);
      code = CTL_EXIT_USAGE;
      goto out;
    }

  if (opt_version)
    {
      printf ("%s %s\n", prog, CTL_VERSION);
      goto out;
    }

  if (argc < 2
      || g_strcmp0 (argv[1], "help") == 0
      || g_strcmp0 (argv[1], "--help") == 0
      || g_strcmp0 (argv[1], "-h") == 0)
    {
      if (argc > 2)
        code = print_command_help (self, prog, argv + 2, argc - 2);
      else
        print_help (self, prog);
      goto out;
    }

  /* Config + context resolution: flags > context > config defaults. */
  config = ctl_config_load (opt_config, &error);
  if (config == NULL)
    {
      fprintf (stderr, "%s: %s\n", prog, error->message);
      g_error_free (error);
      code = CTL_EXIT_USAGE;
      goto out;
    }
  context = ctl_config_resolve_context (config, opt_context, &error);
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
    opt_instance != NULL ? opt_instance : context->instance);
  ctl_invocation_set_host (inv,
    opt_host != NULL ? opt_host : context->host);
  ctl_invocation_set_output (inv,
    opt_output != NULL ? opt_output
    : (context->output != NULL ? context->output : "table"));
  ctl_invocation_set_watch (inv, opt_watch);
  if (opt_timeout > 0)
    ctl_invocation_set_timeout (inv, opt_timeout);
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

    {
      gint consumed = 0;
      CtlCommand *cmd = ctl_command_registry_lookup (
        self->registry, cmd_argv, cmd_argc, &consumed);

      if (cmd == NULL)
        {
          /* Blame the full attempted command, not just the group:
           * `get nuffers' should not report "unknown command 'get'". */
          gchar *attempted = cmd_argc >= 2
            ? g_strdup_printf ("%s %s", cmd_argv[0], cmd_argv[1])
            : g_strdup (cmd_argv[0]);
          gchar *suggestion = suggest_command (self, attempted);

          fprintf (stderr, "%s: unknown command '%s'\n", prog,
                   attempted);
          if (suggestion != NULL)
            fprintf (stderr, "Did you mean '%s %s'?\n", prog,
                     suggestion);
          else
            fprintf (stderr, "Run '%s help' for the command list.\n",
                     prog);
          g_free (attempted);
          g_free (suggestion);
          g_strfreev (cmd_argv);
          code = CTL_EXIT_USAGE;
          goto out;
        }

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
  g_free (opt_context);
  g_free (opt_instance);
  g_free (opt_host);
  g_free (opt_output);
  g_free (opt_config);
  return code;
}
