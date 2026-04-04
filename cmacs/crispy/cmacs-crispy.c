/* cmacs-crispy.c — Crispy C scripting integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Links against libcrispy.  Instantiates CrispyScript and
 * CrispyGccCompiler GObjects.  Objects are created once at init
 * and reused.
 */

#include <config.h>

#ifdef HAVE_CMACS_CRISPY

#include "lisp.h"
#include <crispy.h>

static Lisp_Object Qcrispy_error;

/* Persistent objects — created once, reused across calls. */
static CrispyGccCompiler *cmacs_crispy_compiler = NULL;
static CrispyFileCache *cmacs_crispy_cache = NULL;
static CrispyRepl *cmacs_crispy_repl = NULL;

/* ──────────────────────────────────────────────────────────────────── */
/* Internal helpers                                                    */
/* ──────────────────────────────────────────────────────────────────── */

static void
cmacs_crispy_ensure_init (void)
{
  GError *err = NULL;

  if (cmacs_crispy_compiler == NULL)
    {
      cmacs_crispy_compiler = crispy_gcc_compiler_new (&err);
      if (cmacs_crispy_compiler == NULL)
        {
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qcrispy_error, msg);
        }
    }

  if (cmacs_crispy_cache == NULL)
    cmacs_crispy_cache = crispy_file_cache_new ();
}

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("crispy-eval", Fcrispy_eval, Scrispy_eval, 1, 1, 0,
       doc: /* Compile and execute inline C CODE string.
Returns the exit code as an integer. */)
  (Lisp_Object code)
{
  CrispyScript *script;
  GError *err = NULL;
  gint rc;

  CHECK_STRING (code);
  cmacs_crispy_ensure_init ();

  script = crispy_script_new_from_inline (
    SSDATA (code), NULL,
    CRISPY_COMPILER (cmacs_crispy_compiler),
    CRISPY_CACHE_PROVIDER (cmacs_crispy_cache),
    CRISPY_FLAG_NONE, &err);

  if (script == NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  rc = crispy_script_execute (script, 0, NULL, &err);
  g_object_unref (script);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  return make_fixnum (rc);
}

DEFUN ("crispy-eval-string", Fcrispy_eval_string, Scrispy_eval_string,
       1, 1, 0,
       doc: /* Compile and execute C CODE, capturing stdout as a string.
Returns stdout output. */)
  (Lisp_Object code)
{
  CrispyScript *script;
  GError *err = NULL;
  gint rc;
  gint stdout_pipe[2];
  gchar buf[4096];
  GString *output;
  Lisp_Object result;
  gssize n;
  gint old_stdout;

  CHECK_STRING (code);
  cmacs_crispy_ensure_init ();

  /* Redirect stdout to capture output. */
  if (pipe (stdout_pipe) != 0)
    error ("crispy-eval-string: pipe() failed");

  old_stdout = dup (STDOUT_FILENO);
  dup2 (stdout_pipe[1], STDOUT_FILENO);
  close (stdout_pipe[1]);

  script = crispy_script_new_from_inline (
    SSDATA (code), NULL,
    CRISPY_COMPILER (cmacs_crispy_compiler),
    CRISPY_CACHE_PROVIDER (cmacs_crispy_cache),
    CRISPY_FLAG_NONE, &err);

  if (script == NULL)
    {
      /* Restore stdout before signaling. */
      dup2 (old_stdout, STDOUT_FILENO);
      close (old_stdout);
      close (stdout_pipe[0]);

      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  rc = crispy_script_execute (script, 0, NULL, &err);
  g_object_unref (script);

  /* Restore stdout. */
  fflush (stdout);
  dup2 (old_stdout, STDOUT_FILENO);
  close (old_stdout);

  /* Read captured output. */
  output = g_string_new (NULL);
  while ((n = read (stdout_pipe[0], buf, sizeof (buf) - 1)) > 0)
    {
      buf[n] = '\0';
      g_string_append (output, buf);
    }
  close (stdout_pipe[0]);

  if (err != NULL)
    {
      g_string_free (output, TRUE);
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  result = build_string (output->str);
  g_string_free (output, TRUE);

  (void)rc;
  return result;
}

DEFUN ("crispy-compile", Fcrispy_compile, Scrispy_compile, 1, 1, 0,
       doc: /* Compile FILE as a crispy script.  Return the cached binary path. */)
  (Lisp_Object file)
{
  CrispyScript *script;
  GError *err = NULL;
  const gchar *cached_path;
  Lisp_Object result;

  CHECK_STRING (file);
  cmacs_crispy_ensure_init ();

  script = crispy_script_new_from_file (
    SSDATA (file),
    CRISPY_COMPILER (cmacs_crispy_compiler),
    CRISPY_CACHE_PROVIDER (cmacs_crispy_cache),
    CRISPY_FLAG_NONE, &err);

  if (script == NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  cached_path = crispy_script_get_temp_source_path (script);
  result = cached_path ? build_string (cached_path) : Qnil;
  g_object_unref (script);

  return result;
}

DEFUN ("crispy-run", Fcrispy_run, Scrispy_run, 1, MANY, 0,
       doc: /* Compile and execute a .c script FILE with ARGS.
Returns the exit code.
usage: (crispy-run FILE &rest ARGS) */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  CrispyScript *script;
  GError *err = NULL;
  gint rc;
  gchar **argv;
  gint argc;
  ptrdiff_t i;

  CHECK_STRING (args[0]);
  cmacs_crispy_ensure_init ();

  /* Build argv from elisp args. */
  argc = (gint)(nargs - 1);
  argv = g_new0 (gchar *, argc + 1);
  for (i = 0; i < argc; i++)
    {
      CHECK_STRING (args[i + 1]);
      argv[i] = (gchar *)SSDATA (args[i + 1]);
    }

  script = crispy_script_new_from_file (
    SSDATA (args[0]),
    CRISPY_COMPILER (cmacs_crispy_compiler),
    CRISPY_CACHE_PROVIDER (cmacs_crispy_cache),
    CRISPY_FLAG_NONE, &err);

  if (script == NULL)
    {
      g_free (argv);
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  rc = crispy_script_execute (script, argc, argv, &err);
  g_object_unref (script);
  g_free (argv);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  return make_fixnum (rc);
}

DEFUN ("crispy-repl-eval", Fcrispy_repl_eval, Scrispy_repl_eval, 1, 1, 0,
       doc: /* Evaluate CODE in the persistent crispy REPL.
Returns the exit code. */)
  (Lisp_Object code)
{
  GError *err = NULL;
  gint rc;

  CHECK_STRING (code);
  cmacs_crispy_ensure_init ();

  if (cmacs_crispy_repl == NULL)
    {
      cmacs_crispy_repl = crispy_repl_new (
        CRISPY_COMPILER (cmacs_crispy_compiler),
        CRISPY_CACHE_PROVIDER (cmacs_crispy_cache));

      if (!crispy_repl_start (cmacs_crispy_repl, &err))
        {
          g_clear_object (&cmacs_crispy_repl);
          Lisp_Object msg = build_string (err->message);
          g_error_free (err);
          xsignal1 (Qcrispy_error, msg);
        }
    }

  rc = crispy_repl_eval (cmacs_crispy_repl, SSDATA (code), &err);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  return make_fixnum (rc);
}

DEFUN ("crispy-repl-reset", Fcrispy_repl_reset, Scrispy_repl_reset,
       0, 0, 0,
       doc: /* Reset the persistent crispy REPL state. */)
  (void)
{
  if (cmacs_crispy_repl != NULL)
    crispy_repl_reset (cmacs_crispy_repl);

  return Qnil;
}

DEFUN ("crispy-cache-status", Fcrispy_cache_status, Scrispy_cache_status,
       0, 0, 0,
       doc: /* Return the crispy cache directory path. */)
  (void)
{
  cmacs_crispy_ensure_init ();

  const gchar *dir = crispy_file_cache_get_dir (cmacs_crispy_cache);
  return dir ? build_string (dir) : Qnil;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Init                                                                */
/* ──────────────────────────────────────────────────────────────────── */

void
syms_of_cmacs_crispy (void)
{
  DEFSYM (Qcrispy_error, "crispy-error");

  Fput (Qcrispy_error, Qerror_conditions,
        pure_list (Qcrispy_error, Qerror));
  Fput (Qcrispy_error, Qerror_message,
        build_pure_c_string ("Crispy error"));

  defsubr (&Scrispy_eval);
  defsubr (&Scrispy_eval_string);
  defsubr (&Scrispy_compile);
  defsubr (&Scrispy_run);
  defsubr (&Scrispy_repl_eval);
  defsubr (&Scrispy_repl_reset);
  defsubr (&Scrispy_cache_status);
}

#endif /* HAVE_CMACS_CRISPY */
