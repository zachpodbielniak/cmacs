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

static Lisp_Object Qbacon_error;

/* Persistent shell instance. */
static BaconShell *cmacs_bacon_shell = NULL;

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("bacon-start", Fbacon_start, Sbacon_start, 0, 0, 0,
       doc: /* Create and start a BaconShell instance.
Returns non-nil on success. */)
  (void)
{
  if (cmacs_bacon_shell != NULL)
    return Qt; /* Already running. */

  cmacs_bacon_shell = bacon_shell_new (BACON_FLAG_INTERACTIVE);
  if (cmacs_bacon_shell == NULL)
    xsignal1 (Qbacon_error, build_string ("Failed to create BaconShell"));

  return Qt;
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

DEFUN ("bacon-eval", Fbacon_eval, Sbacon_eval, 1, 1, 0,
       doc: /* Execute COMMAND string in the bacon shell.
Returns the exit code as an integer. */)
  (Lisp_Object command)
{
  gint rc;

  CHECK_STRING (command);

  if (cmacs_bacon_shell == NULL)
    Fbacon_start ();

  rc = bacon_shell_execute_line (cmacs_bacon_shell, SSDATA (command));

  return make_fixnum (rc);
}

DEFUN ("bacon-eval-c", Fbacon_eval_c, Sbacon_eval_c, 1, 1, 0,
       doc: /* Execute a C code block in the bacon shell via crispy.
Returns the exit code as an integer. */)
  (Lisp_Object code)
{
  gint rc;

  CHECK_STRING (code);

  if (cmacs_bacon_shell == NULL)
    Fbacon_start ();

  rc = bacon_shell_execute_c_block (cmacs_bacon_shell, SSDATA (code));

  return make_fixnum (rc);
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
        pure_list (Qbacon_error, Qerror));
  Fput (Qbacon_error, Qerror_message,
        build_pure_c_string ("Bacon shell error"));

  defsubr (&Sbacon_start);
  defsubr (&Sbacon_stop);
  defsubr (&Sbacon_eval);
  defsubr (&Sbacon_eval_c);
  defsubr (&Sbacon_complete);
  defsubr (&Sbacon_environment);
  defsubr (&Sbacon_source);
  defsubr (&Sbacon_alias);
  defsubr (&Sbacon_running_p);
}

#endif /* HAVE_CMACS_BACON */
