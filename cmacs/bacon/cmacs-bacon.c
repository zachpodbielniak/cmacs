/* cmacs-bacon.c — Bacon shell integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Links against libbacon-1.0.  Instantiates BaconShell with its module
 * manager.  I/O is handled through comint-mode on the elisp side.
 */

#include <config.h>

#ifdef HAVE_CMACS_BACON

#include "lisp.h"
#include <bacon.h>
#include <unistd.h>
#include <stdio.h>
#include <fcntl.h>

/* Persistent shell instance. */
static BaconShell *cmacs_bacon_shell = NULL;

/* ──────────────────────────────────────────────────────────────────── */
/* Startup helpers (replicate main.c's post-construction init)         */
/* ──────────────────────────────────────────────────────────────────── */

/* Source an RC file if it exists. */
static void
cmacs_bacon_source_rc (BaconShell *shell, const gchar *path)
{
  if (g_file_test (path, G_FILE_TEST_IS_REGULAR))
    bacon_shell_source_file (shell, path, NULL);
}

/* Source interactive RC files (~/.baconrc). */
static void
cmacs_bacon_source_interactive_rc (BaconShell *shell)
{
  gchar *path = g_build_filename (g_get_home_dir (), ".baconrc", NULL);
  cmacs_bacon_source_rc (shell, path);
  g_free (path);
}

/* Import aliases from bash if source_bashrc=true in config. */
static void
cmacs_bacon_import_bashrc_aliases (BaconShell *shell)
{
  BaconConfig *config;
  gchar *output = NULL;
  gchar **lines, **iter;
  gint status;
  gchar *child_argv[6];
  GSpawnFlags flags;

  config = bacon_shell_get_config (shell);
  if (!bacon_config_get_bool (config, "source_bashrc"))
    return;

  child_argv[0] = (gchar *)"bash";
  child_argv[1] = (gchar *)"--login";
  child_argv[2] = (gchar *)"-i";
  child_argv[3] = (gchar *)"-c";
  child_argv[4] = (gchar *)"alias -p";
  child_argv[5] = NULL;

  flags = G_SPAWN_SEARCH_PATH | G_SPAWN_CHILD_INHERITS_STDIN
          | G_SPAWN_STDERR_TO_DEV_NULL;

  if (!g_spawn_sync (NULL, child_argv, NULL, flags,
                     NULL, NULL, &output, NULL, &status, NULL))
    return;

  if (output == NULL)
    return;

  lines = g_strsplit (output, "\n", -1);
  g_free (output);

  for (iter = lines; *iter != NULL; iter++)
    {
      const gchar *line = *iter;
      const gchar *eq;
      gchar *name, *value;
      GError *qerr = NULL;

      if (!g_str_has_prefix (line, "alias "))
        continue;

      line += 6;
      eq = strchr (line, '=');
      if (eq == NULL)
        continue;

      name = g_strndup (line, (gsize)(eq - line));
      value = g_shell_unquote (eq + 1, &qerr);
      if (value == NULL)
        {
          g_clear_error (&qerr);
          value = g_strdup (eq + 1);
        }

      bacon_shell_set_alias (shell, name, value);
      g_free (name);
      g_free (value);
    }

  g_strfreev (lines);
}

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("bacon-start", Fbacon_start, Sbacon_start, 0, 0, 0,
       doc: /* Create and start a BaconShell instance.
Loads config, sources RC files, and imports bash aliases.
Returns non-nil on success. */)
  (void)
{
  if (cmacs_bacon_shell != NULL)
    return Qt; /* Already running. */

  cmacs_bacon_shell = bacon_shell_new (BACON_FLAG_INTERACTIVE);
  if (cmacs_bacon_shell == NULL)
    xsignal1 (Qbacon_error, build_string ("Failed to create BaconShell"));

  /* Replicate main.c's post-construction startup:
     source RC files and import bash aliases. */
  cmacs_bacon_source_interactive_rc (cmacs_bacon_shell);
  cmacs_bacon_import_bashrc_aliases (cmacs_bacon_shell);

  return Qt;
}

DEFUN ("bacon-get-prompt", Fbacon_get_prompt, Sbacon_get_prompt, 0, 0, 0,
       doc: /* Return the configured prompt format string from bacon config.
Returns nil if no shell is running or prompt is empty. */)
  (void)
{
  BaconConfig *config;
  const gchar *fmt;

  if (cmacs_bacon_shell == NULL)
    return Qnil;

  config = bacon_shell_get_config (cmacs_bacon_shell);
  if (config == NULL)
    return Qnil;

  fmt = bacon_config_get_prompt_format (config);
  if (fmt == NULL || fmt[0] == '\0')
    return Qnil;

  return build_string (fmt);
}

DEFUN ("bacon-stop", Fbacon_stop, Sbacon_stop, 0, 0, 0,
       doc: /* Destroy the BaconShell instance. */)
  (void)
{
  if (cmacs_bacon_shell != NULL)
    {
      bacon_shell_quit (cmacs_bacon_shell);
      g_clear_object (&cmacs_bacon_shell);
    }
  return Qnil;
}

/* Redirect stdout/stderr to a temp file, execute a bacon command,
   restore the original fds, and return a cons of (EXIT-CODE . OUTPUT).
   Uses tmpfile() to avoid pipe-buffer deadlocks with forked children. */
static Lisp_Object
bacon_eval_capturing (BaconShell *shell, const char *text)
{
  FILE *tmp;
  int tmpfd, saved_out, saved_err, saved_in, devnull;
  off_t size;
  char *buf;
  gint rc;
  Lisp_Object output;

  tmp = tmpfile ();
  if (tmp == NULL)
    xsignal1 (Qbacon_error, build_string ("Failed to create capture file"));

  tmpfd = fileno (tmp);
  saved_out = dup (STDOUT_FILENO);
  saved_err = dup (STDERR_FILENO);

  /* Redirect stdin away from the tty so bacon's pipeline code
     sees isatty(STDIN_FILENO)==false and skips tcsetpgrp/setpgid
     job control, which would steal the terminal from Emacs. */
  saved_in = dup (STDIN_FILENO);
  devnull = open ("/dev/null", O_RDONLY);
  if (devnull >= 0)
    dup2 (devnull, STDIN_FILENO);

  dup2 (tmpfd, STDOUT_FILENO);
  dup2 (tmpfd, STDERR_FILENO);

  rc = bacon_shell_execute_line (shell, text);

  /* Flush any libc-buffered output before reading. */
  fflush (stdout);
  fflush (stderr);

  /* Restore original fds. */
  dup2 (saved_out, STDOUT_FILENO);
  dup2 (saved_err, STDERR_FILENO);
  dup2 (saved_in, STDIN_FILENO);
  close (saved_out);
  close (saved_err);
  close (saved_in);
  if (devnull >= 0)
    close (devnull);

  /* Read captured output. */
  size = lseek (tmpfd, 0, SEEK_END);
  if (size > 0)
    {
      lseek (tmpfd, 0, SEEK_SET);
      buf = xmalloc (size + 1);
      read (tmpfd, buf, size);
      buf[size] = '\0';
      output = make_string (buf, size);
      xfree (buf);
    }
  else
    output = empty_unibyte_string;

  fclose (tmp);
  return Fcons (make_fixnum (rc), output);
}

DEFUN ("bacon-eval", Fbacon_eval, Sbacon_eval, 1, 1, 0,
       doc: /* Execute COMMAND string in the bacon shell.
Returns a cons (EXIT-CODE . OUTPUT) where OUTPUT is the captured
stdout and stderr as a string. */)
  (Lisp_Object command)
{
  CHECK_STRING (command);

  if (cmacs_bacon_shell == NULL)
    Fbacon_start ();

  return bacon_eval_capturing (cmacs_bacon_shell, SSDATA (command));
}

DEFUN ("bacon-eval-c", Fbacon_eval_c, Sbacon_eval_c, 1, 1, 0,
       doc: /* Execute a C code block in the bacon shell via crispy.
Returns a cons (EXIT-CODE . OUTPUT). */)
  (Lisp_Object code)
{
  CHECK_STRING (code);

  if (cmacs_bacon_shell == NULL)
    Fbacon_start ();

  /* Route through the same capture mechanism — crispy output
     goes to stdout just like any other command. */
  {
    gchar *wrapped = g_strdup_printf ("{ %s }", SSDATA (code));
    Lisp_Object result = bacon_eval_capturing (cmacs_bacon_shell, wrapped);
    g_free (wrapped);
    return result;
  }
}

DEFUN ("bacon-complete", Fbacon_complete, Sbacon_complete, 1, 1, 0,
       doc: /* Return completion candidates for PREFIX from the bacon shell.
Returns a list of strings. */)
  (Lisp_Object prefix)
{
  BaconModuleManager *mgr;
  Lisp_Object result = Qnil;

  CHECK_STRING (prefix);

  if (cmacs_bacon_shell == NULL)
    return Qnil;

  /* Completions come from bacon's module system.
   * For now, return command lookup as basic completion. */
  {
    BaconExecutable *exec;
    exec = bacon_shell_lookup_command (cmacs_bacon_shell, SSDATA (prefix));
    if (exec != NULL)
      {
        const gchar *name = bacon_executable_get_name (exec);
        if (name != NULL)
          result = Fcons (build_string (name), result);
      }
  }

  (void)mgr;
  return result;
}

DEFUN ("bacon-environment", Fbacon_environment, Sbacon_environment,
       0, 0, 0,
       doc: /* Return the bacon shell environment as an alist.
Each element is (NAME . VALUE). */)
  (void)
{
  /* Environment is accessible via the BaconEnvironment object.
   * Since we cannot iterate it directly from the public API,
   * return the last exit code as a representative value. */
  Lisp_Object result = Qnil;

  if (cmacs_bacon_shell == NULL)
    return Qnil;

  {
    gint last_rc = bacon_shell_get_last_exit_code (cmacs_bacon_shell);
    result = Fcons (Fcons (build_string ("?"),
                           build_string (g_strdup_printf ("%d", last_rc))),
                    result);
  }

  return result;
}

DEFUN ("bacon-source", Fbacon_source, Sbacon_source, 1, 1, 0,
       doc: /* Source FILE in the bacon shell (like `source` or `.`).
Returns non-nil on success. */)
  (Lisp_Object file)
{
  GError *err = NULL;
  gboolean ok;

  CHECK_STRING (file);

  if (cmacs_bacon_shell == NULL)
    Fbacon_start ();

  ok = bacon_shell_source_file (cmacs_bacon_shell, SSDATA (file), &err);

  if (!ok)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qbacon_error, msg);
    }

  return Qt;
}

DEFUN ("bacon-alias", Fbacon_alias, Sbacon_alias, 1, 2, 0,
       doc: /* Get or set a bacon shell alias.
With one arg, return the alias value for NAME.
With two args, set alias NAME to VALUE. */)
  (Lisp_Object name, Lisp_Object value)
{
  CHECK_STRING (name);

  if (cmacs_bacon_shell == NULL)
    Fbacon_start ();

  if (NILP (value))
    {
      const gchar *val = bacon_shell_get_alias (cmacs_bacon_shell,
                                                SSDATA (name));
      return val ? build_string (val) : Qnil;
    }
  else
    {
      CHECK_STRING (value);
      bacon_shell_set_alias (cmacs_bacon_shell, SSDATA (name),
                             SSDATA (value));
      return value;
    }
}

DEFUN ("bacon-running-p", Fbacon_running_p, Sbacon_running_p, 0, 0, 0,
       doc: /* Return non-nil if the bacon shell is running. */)
  (void)
{
  return cmacs_bacon_shell != NULL ? Qt : Qnil;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Init                                                                */
/* ──────────────────────────────────────────────────────────────────── */

void
syms_of_cmacs_bacon (void)
{
  DEFSYM (Qbacon_error, "bacon-error");

  Fput (Qbacon_error, Qerror_conditions,
        Fcons (Qbacon_error, Fcons (Qerror, Qnil)));
  Fput (Qbacon_error, Qerror_message,
        build_string ("Bacon shell error"));

  defsubr (&Sbacon_start);
  defsubr (&Sbacon_stop);
  defsubr (&Sbacon_eval);
  defsubr (&Sbacon_eval_c);
  defsubr (&Sbacon_complete);
  defsubr (&Sbacon_environment);
  defsubr (&Sbacon_source);
  defsubr (&Sbacon_alias);
  defsubr (&Sbacon_running_p);
  defsubr (&Sbacon_get_prompt);
}

#endif /* HAVE_CMACS_BACON */
