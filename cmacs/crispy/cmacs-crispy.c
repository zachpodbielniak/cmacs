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
#include "cmacs-eval-dispatch.h"
#include <crispy.h>
#include <gmodule.h>
#include <unistd.h>
#include <stdio.h>

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
/* CMacs API direct dispatch                                           */
/* ──────────────────────────────────────────────────────────────────── */

/* Register the cmacs-api direct dispatch table so that crispy scripts
 * loaded in-process (via g_module_open) can call back into Emacs
 * without IPC.  The dispatch functions are defined in
 * cmacs-eval-dispatch.c and run on the Emacs main thread.
 *
 * This is safe because crispy_script_execute() calls the script's
 * main() synchronously on the same thread.
 *
 * We load libcmacs-api.so dynamically rather than linking it into
 * temacs, because the library is a runtime component used by crispy
 * scripts.  Pre-loading it here ensures the dispatch table is set
 * before any script executes, and the dynamic linker reuses the
 * same instance when the script's .so resolves its dependency. */

/* Mirror the CmacsApiDirectDispatch layout from cmacs-api.h so we
   can populate it without a build-time dependency on the API lib. */
typedef struct
{
  gchar    *(*eval)       (const gchar *expression, GError **error);
  void      (*find_file)  (const gchar *path);
  void      (*message)    (const gchar *text);
  gboolean  (*gi_require) (const gchar *ns, const gchar *ver,
                           GError **error);
  gchar    *(*gi_call)    (const gchar *ns, const gchar *func,
                           const gchar *const *args, gint n_args,
                           GError **error);
  gchar   **(*gi_list_functions) (const gchar *ns);
} CmacsCrispyDispatch;

static const CmacsCrispyDispatch cmacs_crispy_dispatch = {
  cmacs_dispatch_eval,
  cmacs_dispatch_find_file,
  cmacs_dispatch_message,
  cmacs_dispatch_gi_require,
  cmacs_dispatch_gi_call,
  cmacs_dispatch_gi_list_functions
};

static gboolean cmacs_crispy_dispatch_registered = FALSE;
static GModule *cmacs_crispy_api_module = NULL;

static void
cmacs_crispy_register_dispatch (void)
{
  if (!cmacs_crispy_dispatch_registered)
    {
      gchar *path = g_strconcat (CMACS_SRCDIR, "/../cmacs/api/libcmacs-api.so", NULL);
      cmacs_crispy_api_module = g_module_open (path, G_MODULE_BIND_LAZY);
      g_free (path);

      if (cmacs_crispy_api_module != NULL)
        {
          typedef void (*SetDispatchFunc) (const void *);
          SetDispatchFunc setter = NULL;

          if (g_module_symbol (cmacs_crispy_api_module,
                               "cmacs_api_set_direct_dispatch",
                               (gpointer *) &setter))
            setter (&cmacs_crispy_dispatch);
        }

      cmacs_crispy_dispatch_registered = TRUE;
    }
}

/* Extra compiler flags injected into every crispy script so that
 * `#include <cmacs-api.h>` resolves and `-lcmacs-api` links.
 * Built from the source tree paths at compile time. */
#ifndef CMACS_API_EXTRA_FLAGS
#define CMACS_API_EXTRA_FLAGS \
  "-I" CMACS_SRCDIR "/../cmacs/api " \
  "-L" CMACS_SRCDIR "/../cmacs/api " \
  "-Wl,-rpath," CMACS_SRCDIR "/../cmacs/api " \
  "-lcmacs-api"
#endif

/* Inject the cmacs-api flags into a CrispyScript before execution. */
static void
cmacs_crispy_inject_api_flags (CrispyScript *script)
{
  crispy_script_set_extra_flags (script, CMACS_API_EXTRA_FLAGS);
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
  cmacs_crispy_register_dispatch ();

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

  cmacs_crispy_inject_api_flags (script);
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
  FILE *tmp;
  int tmpfd, saved_out, saved_err;
  off_t size;
  char *buf;
  Lisp_Object result;

  CHECK_STRING (code);
  cmacs_crispy_ensure_init ();
  cmacs_crispy_register_dispatch ();

  tmp = tmpfile ();
  if (tmp == NULL)
    error ("crispy-eval-string: tmpfile() failed");

  tmpfd = fileno (tmp);
  saved_out = dup (STDOUT_FILENO);
  saved_err = dup (STDERR_FILENO);
  dup2 (tmpfd, STDOUT_FILENO);
  dup2 (tmpfd, STDERR_FILENO);

  script = crispy_script_new_from_inline (
    SSDATA (code), NULL,
    CRISPY_COMPILER (cmacs_crispy_compiler),
    CRISPY_CACHE_PROVIDER (cmacs_crispy_cache),
    CRISPY_FLAG_NONE, &err);

  if (script == NULL)
    {
      dup2 (saved_out, STDOUT_FILENO);
      dup2 (saved_err, STDERR_FILENO);
      close (saved_out);
      close (saved_err);
      fclose (tmp);

      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  cmacs_crispy_inject_api_flags (script);
  rc = crispy_script_execute (script, 0, NULL, &err);
  g_object_unref (script);

  fflush (stdout);
  fflush (stderr);
  dup2 (saved_out, STDOUT_FILENO);
  dup2 (saved_err, STDERR_FILENO);
  close (saved_out);
  close (saved_err);

  /* Read captured output. */
  size = lseek (tmpfd, 0, SEEK_END);
  if (size > 0)
    {
      lseek (tmpfd, 0, SEEK_SET);
      buf = xmalloc (size + 1);
      read (tmpfd, buf, size);
      buf[size] = '\0';
      result = make_string (buf, size);
      xfree (buf);
    }
  else
    result = empty_unibyte_string;

  fclose (tmp);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

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
  cmacs_crispy_register_dispatch ();

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

  cmacs_crispy_inject_api_flags (script);
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
  cmacs_crispy_register_dispatch ();

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
        Fcons (Qcrispy_error, Fcons (Qerror, Qnil)));
  Fput (Qcrispy_error, Qerror_message,
        build_string ("Crispy error"));

  defsubr (&Scrispy_eval);
  defsubr (&Scrispy_eval_string);
  defsubr (&Scrispy_compile);
  defsubr (&Scrispy_run);
  defsubr (&Scrispy_repl_eval);
  defsubr (&Scrispy_repl_reset);
  defsubr (&Scrispy_cache_status);
}

#endif /* HAVE_CMACS_CRISPY */
