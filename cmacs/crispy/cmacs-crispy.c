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
#include "epaths.h"
#include "cmacs-crispy.h"
#include "cmacs-eval-dispatch.h"
#include <crispy.h>
#include <gmodule.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* Locate libcmacs-api.so at runtime.  Try the installed path first
 * (from epaths.h), then fall back to the source tree for development. */
static gchar *
cmacs_api_find_so (void)
{
  gchar *installed = g_build_filename (PATH_CMACS_API,
                                       "libcmacs-api.so", NULL);
  if (g_file_test (installed, G_FILE_TEST_EXISTS))
    return installed;
  g_free (installed);

  return g_strconcat (CMACS_SRCDIR, "/../cmacs/api/libcmacs-api.so",
                      NULL);
}

static void
cmacs_crispy_register_dispatch (void)
{
  if (!cmacs_crispy_dispatch_registered)
    {
      gchar *path = cmacs_api_find_so ();
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

/* Build the extra compiler flags for crispy scripts at runtime.
 * Checks the installed path first, falls back to source tree. */
static gchar *
cmacs_api_extra_flags (void)
{
  const gchar *dir;
  gchar *header = g_build_filename (PATH_CMACS_API,
                                    "cmacs-api.h", NULL);
  gboolean installed = g_file_test (header, G_FILE_TEST_EXISTS);
  g_free (header);

  dir = installed
    ? PATH_CMACS_API
    : CMACS_SRCDIR "/../cmacs/api";

  return g_strdup_printf (
    "-I%s -L%s -Wl,-rpath,%s -lcmacs-api", dir, dir, dir);
}

/* Inject the cmacs-api flags into a CrispyScript before execution. */
static void
cmacs_crispy_inject_api_flags (CrispyScript *script)
{
  gchar *flags = cmacs_api_extra_flags ();
  crispy_script_set_extra_flags (script, flags);
  g_free (flags);
}

/* ──────────────────────────────────────────────────────────────────── */
/* stdout/stderr capture                                               */
/* ──────────────────────────────────────────────────────────────────── */

/* Crispy code runs in-process and prints to the real stdout/stderr.
   To return its output as a Lisp string we redirect both fds into a
   tmpfile around execution.  Restoration is registered on the specpdl
   (record_unwind_protect_ptr) because executed code can call back into
   Lisp via cmacs_dispatch_eval, and a signal there would otherwise
   longjmp past the manual restore, leaving Emacs's stdout redirected. */

struct cmacs_crispy_capture
{
  FILE *tmp;            /* tmpfile receiving stdout + stderr */
  int saved_out;        /* dup of the original stdout */
  int saved_err;        /* dup of the original stderr */
  bool active;          /* fds currently redirected */
};

static bool
cmacs_crispy_capture_begin (struct cmacs_crispy_capture *cap)
{
  cap->tmp = tmpfile ();
  if (cap->tmp == NULL)
    return false;

  /* Flush pending Emacs output first, or it would be flushed into
     the tmpfile after the redirect and stolen from the real stdout
     (visible in --batch: princ output vanishing into captures). */
  fflush (stdout);
  fflush (stderr);

  cap->saved_out = dup (STDOUT_FILENO);
  cap->saved_err = dup (STDERR_FILENO);
  dup2 (fileno (cap->tmp), STDOUT_FILENO);
  dup2 (fileno (cap->tmp), STDERR_FILENO);
  cap->active = true;
  return true;
}

/* Restore the real stdout/stderr.  Safe to call more than once. */
static void
cmacs_crispy_capture_restore (struct cmacs_crispy_capture *cap)
{
  if (!cap->active)
    return;

  fflush (stdout);
  fflush (stderr);
  dup2 (cap->saved_out, STDOUT_FILENO);
  dup2 (cap->saved_err, STDERR_FILENO);
  close (cap->saved_out);
  close (cap->saved_err);
  cap->active = false;
}

/* Unwind handler: runs on non-local exit while a capture is active.
   The captured output is discarded; the signal is what matters. */
static void
cmacs_crispy_capture_unwind (void *arg)
{
  struct cmacs_crispy_capture *cap = arg;

  cmacs_crispy_capture_restore (cap);
  if (cap->tmp != NULL)
    {
      fclose (cap->tmp);
      cap->tmp = NULL;
    }
}

/* Restore the fds and return the captured output as a Lisp string.
   The later unbind_to of the unwind entry becomes a no-op. */
static Lisp_Object
cmacs_crispy_capture_end (struct cmacs_crispy_capture *cap)
{
  int tmpfd;
  off_t size;
  Lisp_Object result = empty_unibyte_string;

  cmacs_crispy_capture_restore (cap);

  tmpfd = fileno (cap->tmp);
  size = lseek (tmpfd, 0, SEEK_END);
  if (size > 0)
    {
      char *buf = xmalloc (size + 1);
      ssize_t nread;

      lseek (tmpfd, 0, SEEK_SET);
      nread = read (tmpfd, buf, size);
      if (nread > 0)
        result = make_string (buf, nread);
      xfree (buf);
    }

  fclose (cap->tmp);
  cap->tmp = NULL;
  return result;
}

/* Lazily create the persistent CrispyRepl.  Deliberately does NOT call
   crispy_repl_start: that enters a blocking readline loop on stdin and
   is only for the terminal REPL (cmacs --crispy).  crispy_repl_eval
   works standalone. */
static void
cmacs_crispy_ensure_repl (void)
{
  cmacs_crispy_ensure_init ();
  cmacs_crispy_register_dispatch ();

  if (cmacs_crispy_repl == NULL)
    {
      gchar *flags;

      cmacs_crispy_repl = crispy_repl_new (
        CRISPY_COMPILER (cmacs_crispy_compiler),
        CRISPY_CACHE_PROVIDER (cmacs_crispy_cache));

      /* Let REPL code call back into Emacs through libcmacs-api,
         like one-shot scripts do (cmacs_crispy_inject_api_flags). */
      flags = cmacs_api_extra_flags ();
      crispy_repl_set_extra_flags (cmacs_crispy_repl, flags);
      g_free (flags);
    }
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
  struct cmacs_crispy_capture cap = { 0 };
  specpdl_ref count;
  Lisp_Object result;

  CHECK_STRING (code);
  cmacs_crispy_ensure_init ();
  cmacs_crispy_register_dispatch ();

  count = SPECPDL_INDEX ();
  record_unwind_protect_ptr (cmacs_crispy_capture_unwind, &cap);

  if (!cmacs_crispy_capture_begin (&cap))
    error ("crispy-eval-string: tmpfile() failed");

  script = crispy_script_new_from_inline (
    SSDATA (code), NULL,
    CRISPY_COMPILER (cmacs_crispy_compiler),
    CRISPY_CACHE_PROVIDER (cmacs_crispy_cache),
    CRISPY_FLAG_NONE, &err);

  if (script == NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);     /* unwind restores the fds */
    }

  cmacs_crispy_inject_api_flags (script);
  crispy_script_execute (script, 0, NULL, &err);
  g_object_unref (script);

  result = cmacs_crispy_capture_end (&cap);
  unbind_to (count, Qnil);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

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
Returns the exit code.  Output goes to Emacs's own stdout; use
`crispy-repl-eval-string' to capture it instead. */)
  (Lisp_Object code)
{
  GError *err = NULL;
  gint rc;

  CHECK_STRING (code);
  cmacs_crispy_ensure_repl ();

  rc = crispy_repl_eval (cmacs_crispy_repl, SSDATA (code), &err);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  return make_fixnum (rc);
}

DEFUN ("crispy-repl-eval-string", Fcrispy_repl_eval_string,
       Scrispy_repl_eval_string, 1, 1, 0,
       doc: /* Evaluate CODE in the persistent crispy REPL, capturing output.
Preprocessor directives, function definitions, and type declarations
accumulate in the REPL preamble and stay in scope for later calls.
Bare expressions (no trailing semicolon) are auto-printed as
"=> VALUE".  Returns the combined stdout and stderr output as a
string.  Compilation errors signal `crispy-error' with the gcc
diagnostic. */)
  (Lisp_Object code)
{
  GError *err = NULL;
  struct cmacs_crispy_capture cap = { 0 };
  specpdl_ref count;
  Lisp_Object result;

  CHECK_STRING (code);
  cmacs_crispy_ensure_repl ();

  count = SPECPDL_INDEX ();
  record_unwind_protect_ptr (cmacs_crispy_capture_unwind, &cap);

  if (!cmacs_crispy_capture_begin (&cap))
    error ("crispy-repl-eval-string: tmpfile() failed");

  crispy_repl_eval (cmacs_crispy_repl, SSDATA (code), &err);

  result = cmacs_crispy_capture_end (&cap);
  unbind_to (count, Qnil);

  if (err != NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qcrispy_error, msg);
    }

  return result;
}

DEFUN ("crispy-repl-preamble", Fcrispy_repl_preamble,
       Scrispy_repl_preamble, 0, 0, 0,
       doc: /* Return the accumulated crispy REPL preamble as a string.
Returns an empty string if the REPL has not evaluated anything yet. */)
  (void)
{
  const gchar *preamble;

  if (cmacs_crispy_repl == NULL)
    return empty_unibyte_string;

  preamble = crispy_repl_get_preamble (cmacs_crispy_repl);
  return preamble ? build_string (preamble) : empty_unibyte_string;
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
/* cmacs --crispy: batch script mode (no Emacs initialization)         */
/* ──────────────────────────────────────────────────────────────────── */

/* State for scanning C chunk boundaries in piped REPL input. */
struct cmacs_crispy_scan
{
  int depth;            /* net {([ vs })] depth */
  bool in_string;
  bool in_char;
  bool in_comment;      /* inside a block comment */
};

/* Update SCAN with one LINE of C code, ignoring delimiters inside
   string/character literals and comments.  Line comments end at the
   line; strings and character literals do not span lines. */
static void
cmacs_crispy_scan_line (struct cmacs_crispy_scan *scan, const char *line)
{
  const char *p;
  bool in_line_comment = false;

  for (p = line; *p != '\0'; p++)
    {
      char c = *p;

      if (in_line_comment)
        continue;
      if (scan->in_comment)
        {
          if (c == '*' && p[1] == '/')
            {
              scan->in_comment = false;
              p++;
            }
          continue;
        }
      if (scan->in_string)
        {
          if (c == '\\' && p[1] != '\0')
            p++;
          else if (c == '"')
            scan->in_string = false;
          continue;
        }
      if (scan->in_char)
        {
          if (c == '\\' && p[1] != '\0')
            p++;
          else if (c == '\'')
            scan->in_char = false;
          continue;
        }

      switch (c)
        {
        case '"':
          scan->in_string = true;
          break;
        case '\'':
          scan->in_char = true;
          break;
        case '/':
          if (p[1] == '/')
            in_line_comment = true;
          else if (p[1] == '*')
            {
              scan->in_comment = true;
              p++;
            }
          break;
        case '{': case '(': case '[':
          scan->depth++;
          break;
        case '}': case ')': case ']':
          scan->depth--;
          break;
        }
    }

  scan->in_string = false;
  scan->in_char = false;
}

/* Evaluate piped stdin through the persistent REPL without printing
   the banner or prompts: lines accumulate until braces balance, then
   each chunk is evaluated with full REPL semantics (preamble
   accumulation, "=> VALUE" auto-print).  Only the evaluated code's
   own output reaches stdout; errors go to stderr.  Returns the
   process exit code. */
static int
cmacs_crispy_eval_stdin (CrispyRepl *repl)
{
  GString *all = g_string_new (NULL);
  GString *accum = g_string_new (NULL);
  struct cmacs_crispy_scan scan = { 0, false, false, false };
  char buf[4096];
  size_t n;
  gchar **lines, **lp;
  int rc = 0;
  bool had_error = false;

  while ((n = fread (buf, 1, sizeof buf, stdin)) > 0)
    g_string_append_len (all, buf, n);

  lines = g_strsplit (all->str, "\n", -1);
  for (lp = lines; *lp != NULL; lp++)
    {
      cmacs_crispy_scan_line (&scan, *lp);
      if (accum->len > 0)
        g_string_append_c (accum, '\n');
      g_string_append (accum, *lp);

      /* Keep accumulating inside a brace block or comment. */
      if (*(lp + 1) != NULL && (scan.depth > 0 || scan.in_comment))
        continue;
      scan.depth = 0;

      {
        gchar *trimmed = g_strstrip (g_strdup (accum->str));

        if (*trimmed != '\0')
          {
            GError *err = NULL;

            rc = crispy_repl_eval (repl, accum->str, &err);
            if (err != NULL)
              {
                fprintf (stderr, "cmacs --crispy: %s%s", err->message,
                         g_str_has_suffix (err->message, "\n")
                         ? "" : "\n");
                g_error_free (err);
                had_error = true;
              }
          }
        g_free (trimmed);
      }
      g_string_truncate (accum, 0);
    }

  g_strfreev (lines);
  g_string_free (accum, TRUE);
  g_string_free (all, TRUE);

  if (had_error)
    return 1;
  return rc < 0 ? 1 : rc;
}

/* Called from main() in emacs.c when --crispy is detected, before any
   Emacs initialization.  Runs crispy code without the editor:

     emacs --crispy SCRIPT [ARGS...]   run a .c script, propagate exit code
     emacs --crispy -i CODE            run inline C code
     emacs --crispy -                  read a script from stdin
     emacs --crispy                    interactive terminal REPL on a
                                       tty; with piped stdin, evaluate
                                       it quietly with REPL semantics

   No Lisp exists at this point, so the in-process Emacs dispatch table
   is not registered; scripts still compile and link against
   libcmacs-api, whose transports can reach a separately running cmacs.
   Never returns. */
_Noreturn void
cmacs_crispy_main (int argc, char **argv, int crispy_idx)
{
  CrispyGccCompiler *compiler;
  CrispyFileCache *cache;
  GError *err = NULL;
  gchar *api_flags;
  int first = crispy_idx + 1;
  int rc = 0;

  compiler = crispy_gcc_compiler_new (&err);
  if (compiler == NULL)
    {
      fprintf (stderr, "cmacs --crispy: %s\n", err->message);
      exit (1);
    }
  cache = crispy_file_cache_new ();
  api_flags = cmacs_api_extra_flags ();

  if (first >= argc)
    {
      /* No arguments: on a tty, the interactive terminal REPL
         (readline loop with its own :help / :type / :load /
         :preamble commands); with piped stdin, evaluate it quietly
         -- no banner, no prompts, just the code's output. */
      CrispyRepl *repl = crispy_repl_new (CRISPY_COMPILER (compiler),
                                          CRISPY_CACHE_PROVIDER (cache));
      crispy_repl_set_extra_flags (repl, api_flags);
      if (!isatty (STDIN_FILENO))
        rc = cmacs_crispy_eval_stdin (repl);
      else if (!crispy_repl_start (repl, &err))
        {
          fprintf (stderr, "cmacs --crispy: %s\n", err->message);
          g_error_free (err);
          rc = 1;
        }
      g_object_unref (repl);
    }
  else
    {
      CrispyScript *script;
      int exec_argc;
      char **exec_argv;

      if (strcmp (argv[first], "-i") == 0
          || strcmp (argv[first], "--inline") == 0)
        {
          if (first + 1 >= argc)
            {
              fprintf (stderr, "cmacs --crispy: -i requires CODE\n");
              exit (1);
            }
          script = crispy_script_new_from_inline (
            argv[first + 1], NULL, CRISPY_COMPILER (compiler),
            CRISPY_CACHE_PROVIDER (cache), CRISPY_FLAG_NONE, &err);
          exec_argc = argc - (first + 1);
          exec_argv = &argv[first + 1];
        }
      else if (strcmp (argv[first], "-") == 0)
        {
          script = crispy_script_new_from_stdin (
            CRISPY_COMPILER (compiler), CRISPY_CACHE_PROVIDER (cache),
            CRISPY_FLAG_NONE, &err);
          exec_argc = argc - first;
          exec_argv = &argv[first];
        }
      else
        {
          script = crispy_script_new_from_file (
            argv[first], CRISPY_COMPILER (compiler),
            CRISPY_CACHE_PROVIDER (cache), CRISPY_FLAG_NONE, &err);
          exec_argc = argc - first;
          exec_argv = &argv[first];
        }

      if (script == NULL)
        {
          fprintf (stderr, "cmacs --crispy: %s\n", err->message);
          exit (1);
        }

      crispy_script_set_extra_flags (script, api_flags);
      rc = crispy_script_execute (script, exec_argc, exec_argv, &err);
      g_object_unref (script);

      if (err != NULL)
        {
          fprintf (stderr, "cmacs --crispy: %s\n", err->message);
          g_error_free (err);
          if (rc == 0)
            rc = 1;
        }
    }

  g_free (api_flags);
  g_object_unref (cache);
  g_object_unref (compiler);
  exit (rc < 0 ? 1 : rc);
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
  defsubr (&Scrispy_repl_eval_string);
  defsubr (&Scrispy_repl_preamble);
  defsubr (&Scrispy_repl_reset);
  defsubr (&Scrispy_cache_status);
}

#endif /* HAVE_CMACS_CRISPY */
