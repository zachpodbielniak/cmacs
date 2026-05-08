/*
 * cmacs-cintrospect-jit.c — runtime C compile-and-call (Phase 2)
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-cintrospect-jit.h for the rationale on why we spawn gcc
 * instead of using libgccjit directly.
 */

#include <config.h>

#ifdef HAVE_CMACS_CINTROSPECT

#include "lisp.h"
#include "cmacs-cintrospect-jit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <ctype.h>

/* ── Handle registry ─────────────────────────────────────────────── */

typedef struct CmacsJitHandle
{
  intmax_t id;
  void *dl_handle;
  void *fn_addr;
  char *fn_name;
  char *src_path;       /* /tmp/cmacs-jit-<id>.c (kept for debugging) */
  char *so_path;        /* /tmp/cmacs-jit-<id>.so */
  CmacsCintroJitSig sig;
  /* Persisted source for `cmacs-c-handle-info'. */
  char *source;
  char *expected_sig;
  struct CmacsJitHandle *next;
} CmacsJitHandle;

static CmacsJitHandle *jit_handles_head;
static intmax_t jit_next_handle_id = 1;
static pthread_mutex_t jit_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Coordinates with src/comp.c's libgccjit context: even though we
 * use a subprocess, we still hold the same mutex during compile so
 * native-comp doesn't try to recycle its context out from under a
 * concurrent JIT compile.  comp.c side intentionally lives without
 * this mutex --- we ONLY use it to serialise our own gcc spawns
 * relative to comp.c's libgccjit calls IF that integration lands.
 * For Phase 2 v1 we just hold a local mutex around the whole
 * compile-and-register dance. */
static inline void jit_lock (void)   { pthread_mutex_lock (&jit_mutex); }
static inline void jit_unlock (void) { pthread_mutex_unlock (&jit_mutex); }

/* ── Diagnostics buffer (shared across compile invocations) ───────── */

static char *jit_last_diagnostics;

static void
set_diagnostics (const char *s)
{
  free (jit_last_diagnostics);
  jit_last_diagnostics = s ? strdup (s) : NULL;
}

/* ── Lifecycle ────────────────────────────────────────────────────── */

bool
cmacs_cintrospect_jit_init (void)
{
  /* Nothing eager --- compile-on-demand. */
  return true;
}

void
cmacs_cintrospect_jit_shutdown (void)
{
  jit_lock ();
  CmacsJitHandle *h = jit_handles_head;
  while (h != NULL)
    {
      CmacsJitHandle *next = h->next;
      if (h->dl_handle) dlclose (h->dl_handle);
      if (h->so_path) unlink (h->so_path);
      if (h->src_path) unlink (h->src_path);
      free (h->fn_name);
      free (h->src_path);
      free (h->so_path);
      free (h->source);
      free (h->expected_sig);
      free (h);
      h = next;
    }
  jit_handles_head = NULL;
  free (jit_last_diagnostics);
  jit_last_diagnostics = NULL;
  jit_unlock ();
}

/* ── Signature parser ─────────────────────────────────────────────── */

/* Accepts:
 *   "Lisp_Object(void)"                              → SIG_VOID
 *   "Lisp_Object(Lisp_Object)"                       → SIG_A1
 *   ...
 *   "Lisp_Object(Lisp_Object,Lisp_Object,...)"       → SIG_AN  (1≤N≤8)
 *   "Lisp_Object(MANY)"                              → SIG_MANY
 *   "Lisp_Object(ptrdiff_t,Lisp_Object*)"            → SIG_MANY
 *   "int(int)"                                       → SIG_INT_INT
 *   "int(int,int)"                                   → SIG_INT_INT_INT
 *
 * Whitespace is collapsed before matching.  Returns -1 on parse
 * failure. */
static int
parse_signature (const char *sig_in)
{
  if (sig_in == NULL || sig_in[0] == '\0')
    return -1;

  /* Collapse all whitespace. */
  size_t n = strlen (sig_in);
  char *buf = malloc (n + 1);
  if (buf == NULL) return -1;
  size_t bi = 0;
  for (size_t i = 0; i < n; i++)
    if (!isspace ((unsigned char) sig_in[i]))
      buf[bi++] = sig_in[i];
  buf[bi] = '\0';

  int result = -1;
  if (strcmp (buf, "Lisp_Object(void)") == 0)
    result = CMACS_CINTRO_JIT_SIG_VOID;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A1;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A2;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A3;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A4;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A5;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A6;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A7;
  else if (strcmp (buf, "Lisp_Object(Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object,Lisp_Object)") == 0)
    result = CMACS_CINTRO_JIT_SIG_A8;
  else if (strcmp (buf, "Lisp_Object(MANY)") == 0
           || strcmp (buf, "Lisp_Object(ptrdiff_t,Lisp_Object*)") == 0)
    result = CMACS_CINTRO_JIT_SIG_MANY;
  else if (strcmp (buf, "int(int)") == 0)
    result = CMACS_CINTRO_JIT_SIG_INT_INT;
  else if (strcmp (buf, "int(int,int)") == 0)
    result = CMACS_CINTRO_JIT_SIG_INT_INT_INT;

  free (buf);
  return result;
}

/* ── Compile the source via gcc subprocess ───────────────────────── */

#ifndef CMACS_SRCDIR
# define CMACS_SRCDIR "."
#endif

/* Build the include flags pointing at cmacs's source tree.  We use
 * the runtime-known CMACS_SRCDIR macro that src/Makefile.in injects
 * (`-DCMACS_SRCDIR=...').  This lets a JIT'd `#include "lisp.h"'
 * work in any build tree. */
static int
spawn_gcc_compile (const char *src_path, const char *so_path,
                   char **diag_out)
{
  /* Build a stderr capture pipe. */
  int err_pipe[2];
  if (pipe (err_pipe) != 0)
    return -1;

  pid_t pid = fork ();
  if (pid < 0)
    {
      close (err_pipe[0]);
      close (err_pipe[1]);
      return -1;
    }

  if (pid == 0)
    {
      /* Child. */
      close (err_pipe[0]);
      dup2 (err_pipe[1], STDERR_FILENO);
      close (err_pipe[1]);

      /* Build include args.  CMACS_SRCDIR is the absolute path to
       * `src/' (the cmacs source); .. is the cmacs root, ../lib is
       * gnulib. */
      char inc1[4096], inc2[4096], confh[4096], lisph[4096], extra1[4096];
      snprintf (inc1, sizeof inc1, "-I%s", CMACS_SRCDIR);
      snprintf (inc2, sizeof inc2, "-I%s/../lib", CMACS_SRCDIR);
      snprintf (confh, sizeof confh, "-include%s/config.h", CMACS_SRCDIR);
      snprintf (lisph, sizeof lisph, "-include%s/lisp.h", CMACS_SRCDIR);
      snprintf (extra1, sizeof extra1, "-I%s/../cmacs", CMACS_SRCDIR);

      /* lisp.h is pre-included so user snippets can refer to
       * Lisp_Object, make_fixnum, Fcons, etc. directly without
       * explicit `#include "lisp.h"'.  Cost is one extra cpp pass
       * per JIT compile; gcc startup dwarfs it. */
      char *const argv[] =
        {
          (char *) "gcc",
          (char *) "-shared", (char *) "-fPIC",
          (char *) "-O0",
          (char *) "-g", (char *) "-gdwarf-5",
          (char *) "-fno-omit-frame-pointer",
          (char *) "-Wno-int-conversion",
          (char *) "-Wno-implicit-function-declaration",
          inc1, inc2, extra1, confh, lisph,
          (char *) "-o", (char *) so_path,
          (char *) src_path,
          NULL,
        };
      execvp ("gcc", argv);
      _exit (127);
    }

  /* Parent: read stderr fully, then wait. */
  close (err_pipe[1]);
  size_t cap = 8192, len = 0;
  char *err_buf = malloc (cap);
  if (err_buf == NULL)
    {
      close (err_pipe[0]);
      waitpid (pid, NULL, 0);
      return -1;
    }
  for (;;)
    {
      if (len + 1024 > cap)
        {
          cap *= 2;
          char *nb = realloc (err_buf, cap);
          if (nb == NULL) break;
          err_buf = nb;
        }
      ssize_t n = read (err_pipe[0], err_buf + len, cap - len - 1);
      if (n <= 0) break;
      len += (size_t) n;
    }
  err_buf[len] = '\0';
  close (err_pipe[0]);

  int status = 0;
  if (waitpid (pid, &status, 0) < 0)
    {
      *diag_out = err_buf;
      return -1;
    }

  *diag_out = err_buf;
  if (WIFEXITED (status) && WEXITSTATUS (status) == 0)
    return 0;
  return WIFEXITED (status) ? WEXITSTATUS (status) : -1;
}

/* ── Public: cmacs-c-compile ─────────────────────────────────────── */

DEFUN ("cmacs-c-compile", Fcmacs_c_compile,
       Scmacs_c_compile, 2, 3, 0,
       doc: /* Compile SOURCE (a string of C) and return a handle ID
to its function FUNC-NAME.  Optional EXPECTED-SIG is a signature
string like "Lisp_Object(Lisp_Object)" which the parser uses to
dispatch later `cmacs-c-call' invocations.

The source is compiled by spawning `gcc' as a subprocess with
debug info enabled, so the compiled function is itself
DWARF-introspectable via `cmacs-c-symbol-info'.  Cmacs internals
(make_string, Fcons, build_string, ...) resolve at dlopen time
because cmacs is linked with `-Wl,--export-dynamic'.

Returns the integer handle ID.  On compile failure, raises
`cmacs-cintrospect-compile-error' with the gcc diagnostics text.

Default EXPECTED-SIG is "Lisp_Object(void)".  */)
  (Lisp_Object source, Lisp_Object func_name, Lisp_Object expected_sig)
{
  CHECK_STRING (source);
  CHECK_STRING (func_name);
  const char *sig_str = NILP (expected_sig)
                        ? "Lisp_Object(void)"
                        : (CHECK_STRING (expected_sig), SSDATA (expected_sig));
  int sig = parse_signature (sig_str);
  if (sig < 0)
    xsignal2 (Qerror,
              build_string ("cmacs-c-compile: unsupported signature"),
              build_string (sig_str));

  jit_lock ();
  intmax_t id = jit_next_handle_id++;
  jit_unlock ();

  /* Write source to /tmp/cmacs-jit-<id>.c. */
  char src_path[256], so_path[256];
  snprintf (src_path, sizeof src_path,
            "/tmp/cmacs-jit-%lld.c", (long long) id);
  snprintf (so_path, sizeof so_path,
            "/tmp/cmacs-jit-%lld.so", (long long) id);

  FILE *f = fopen (src_path, "w");
  if (f == NULL)
    xsignal2 (Qerror,
              build_string ("cmacs-c-compile: can't open temp source"),
              build_string (strerror (errno)));
  fwrite (SDATA (source), 1, SBYTES (source), f);
  fputc ('\n', f);
  fclose (f);

  /* Spawn gcc. */
  char *diag = NULL;
  int rc = spawn_gcc_compile (src_path, so_path, &diag);
  if (rc != 0)
    {
      set_diagnostics (diag);
      char *msg = NULL;
      int unused = asprintf (&msg, "compile failed (rc=%d):\n%s",
                             rc, diag ? diag : "(no diagnostics)");
      (void) unused;
      Lisp_Object lmsg = build_string (msg ? msg : "compile failed");
      free (msg);
      free (diag);
      unlink (src_path);
      xsignal1 (intern ("cmacs-cintrospect-compile-error"), lmsg);
    }
  set_diagnostics (diag);
  free (diag);

  /* dlopen + dlsym. */
  void *dlh = dlopen (so_path, RTLD_NOW | RTLD_LOCAL);
  if (dlh == NULL)
    {
      Lisp_Object e = build_string (dlerror ());
      unlink (so_path); unlink (src_path);
      xsignal2 (Qerror, build_string ("cmacs-c-compile: dlopen failed"), e);
    }
  void *fn = dlsym (dlh, SSDATA (func_name));
  if (fn == NULL)
    {
      Lisp_Object e = build_string (dlerror ());
      dlclose (dlh);
      unlink (so_path); unlink (src_path);
      xsignal2 (Qerror,
                build_string ("cmacs-c-compile: dlsym failed --- function not found"),
                e);
    }

  /* Register handle. */
  CmacsJitHandle *h = calloc (1, sizeof *h);
  h->id           = id;
  h->dl_handle    = dlh;
  h->fn_addr      = fn;
  h->fn_name      = strdup (SSDATA (func_name));
  h->src_path     = strdup (src_path);
  h->so_path      = strdup (so_path);
  h->source       = strdup (SSDATA (source));
  h->expected_sig = strdup (sig_str);
  h->sig          = sig;

  jit_lock ();
  h->next = jit_handles_head;
  jit_handles_head = h;
  jit_unlock ();

  return make_int (id);
}

/* ── Public: cmacs-c-call ────────────────────────────────────────── */

static CmacsJitHandle *
find_handle_locked (intmax_t id)
{
  for (CmacsJitHandle *h = jit_handles_head; h != NULL; h = h->next)
    if (h->id == id)
      return h;
  return NULL;
}

DEFUN ("cmacs-c-call", Fcmacs_c_call,
       Scmacs_c_call, 1, MANY, 0,
       doc: /* Call HANDLE (from `cmacs-c-compile') with ARGS.

Dispatches based on the handle's signature: a Lisp_Object signature
takes Lisp_Object args and returns a Lisp_Object; an int(int) /
int(int,int) signature takes integers and returns an integer.

usage: (cmacs-c-call HANDLE &rest ARGS)  */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  if (nargs < 1)
    xsignal0 (Qwrong_number_of_arguments);
  CHECK_INTEGER (args[0]);
  intmax_t id = FIXNUMP (args[0])
                ? (intmax_t) XFIXNUM (args[0])
                : (intmax_t) bignum_to_intmax (args[0]);

  jit_lock ();
  CmacsJitHandle *h = find_handle_locked (id);
  jit_unlock ();
  if (h == NULL)
    xsignal2 (Qerror,
              build_string ("cmacs-c-call: handle not found"),
              args[0]);

  ptrdiff_t actual_args = nargs - 1;
  Lisp_Object *a = args + 1;

  switch (h->sig)
    {
    case CMACS_CINTRO_JIT_SIG_VOID:
      if (actual_args != 0) goto wrong_arity;
      return ((Lisp_Object (*) (void)) h->fn_addr) ();
    case CMACS_CINTRO_JIT_SIG_A1:
      if (actual_args != 1) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object)) h->fn_addr) (a[0]);
    case CMACS_CINTRO_JIT_SIG_A2:
      if (actual_args != 2) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object))
              h->fn_addr) (a[0], a[1]);
    case CMACS_CINTRO_JIT_SIG_A3:
      if (actual_args != 3) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object, Lisp_Object))
              h->fn_addr) (a[0], a[1], a[2]);
    case CMACS_CINTRO_JIT_SIG_A4:
      if (actual_args != 4) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object))
              h->fn_addr) (a[0], a[1], a[2], a[3]);
    case CMACS_CINTRO_JIT_SIG_A5:
      if (actual_args != 5) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object, Lisp_Object))
              h->fn_addr) (a[0], a[1], a[2], a[3], a[4]);
    case CMACS_CINTRO_JIT_SIG_A6:
      if (actual_args != 6) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object, Lisp_Object, Lisp_Object))
              h->fn_addr) (a[0], a[1], a[2], a[3], a[4], a[5]);
    case CMACS_CINTRO_JIT_SIG_A7:
      if (actual_args != 7) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object))
              h->fn_addr) (a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    case CMACS_CINTRO_JIT_SIG_A8:
      if (actual_args != 8) goto wrong_arity;
      return ((Lisp_Object (*) (Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object, Lisp_Object, Lisp_Object,
                                Lisp_Object, Lisp_Object))
              h->fn_addr) (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    case CMACS_CINTRO_JIT_SIG_MANY:
      return ((Lisp_Object (*) (ptrdiff_t, Lisp_Object *))
              h->fn_addr) (actual_args, a);
    case CMACS_CINTRO_JIT_SIG_INT_INT:
      {
        if (actual_args != 1) goto wrong_arity;
        CHECK_FIXNUM (a[0]);
        int (*f) (int) = (int (*) (int)) h->fn_addr;
        return make_fixnum (f ((int) XFIXNUM (a[0])));
      }
    case CMACS_CINTRO_JIT_SIG_INT_INT_INT:
      {
        if (actual_args != 2) goto wrong_arity;
        CHECK_FIXNUM (a[0]); CHECK_FIXNUM (a[1]);
        int (*f) (int, int) = (int (*) (int, int)) h->fn_addr;
        return make_fixnum (f ((int) XFIXNUM (a[0]), (int) XFIXNUM (a[1])));
      }
    }
 wrong_arity:
  xsignal0 (Qwrong_number_of_arguments);
}

/* ── Public: cmacs-c-handle-info ─────────────────────────────────── */

DEFUN ("cmacs-c-handle-info", Fcmacs_c_handle_info,
       Scmacs_c_handle_info, 1, 1, 0,
       doc: /* Return a plist of metadata for HANDLE: :id :fn-name
:fn-addr :signature :so-path :source :diagnostics.

Returns nil if HANDLE is not found.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  intmax_t id = FIXNUMP (handle)
                ? (intmax_t) XFIXNUM (handle)
                : (intmax_t) bignum_to_intmax (handle);
  jit_lock ();
  CmacsJitHandle *h = find_handle_locked (id);
  Lisp_Object out = Qnil;
  if (h != NULL)
    {
      out = nconc2 (out, list2 (intern (":id"),
                                make_int (h->id)));
      out = nconc2 (out, list2 (intern (":fn-name"),
                                build_string (h->fn_name)));
      out = nconc2 (out, list2 (intern (":fn-addr"),
                                make_uint ((uintmax_t) (uintptr_t) h->fn_addr)));
      out = nconc2 (out, list2 (intern (":signature"),
                                build_string (h->expected_sig)));
      out = nconc2 (out, list2 (intern (":so-path"),
                                build_string (h->so_path)));
      out = nconc2 (out, list2 (intern (":source"),
                                build_string (h->source)));
      if (jit_last_diagnostics)
        out = nconc2 (out, list2 (intern (":diagnostics"),
                                  build_string (jit_last_diagnostics)));
    }
  jit_unlock ();
  return out;
}

/* ── Public: cmacs-c-handle-dispose ──────────────────────────────── */

DEFUN ("cmacs-c-handle-dispose", Fcmacs_c_handle_dispose,
       Scmacs_c_handle_dispose, 1, 1, 0,
       doc: /* Dispose of a JIT compilation HANDLE: dlclose the .so,
remove temp files, and unregister.  Returns t on success, nil if the
handle was unknown.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  intmax_t id = FIXNUMP (handle)
                ? (intmax_t) XFIXNUM (handle)
                : (intmax_t) bignum_to_intmax (handle);
  jit_lock ();
  CmacsJitHandle **link = &jit_handles_head;
  while (*link != NULL && (*link)->id != id)
    link = &(*link)->next;
  CmacsJitHandle *h = *link;
  if (h == NULL)
    {
      jit_unlock ();
      return Qnil;
    }
  *link = h->next;
  jit_unlock ();

  if (h->dl_handle) dlclose (h->dl_handle);
  if (h->so_path)   unlink (h->so_path);
  if (h->src_path)  unlink (h->src_path);
  free (h->fn_name);
  free (h->src_path);
  free (h->so_path);
  free (h->source);
  free (h->expected_sig);
  free (h);
  return Qt;
}

/* ── Public C-side helpers (used by cpatch) ──────────────────────── */

void *
cmacs_cintrospect_jit_handle_addr (intmax_t handle_id)
{
  jit_lock ();
  CmacsJitHandle *h = find_handle_locked (handle_id);
  void *addr = h ? h->fn_addr : NULL;
  jit_unlock ();
  return addr;
}

int
cmacs_cintrospect_jit_handle_sig (intmax_t handle_id)
{
  jit_lock ();
  CmacsJitHandle *h = find_handle_locked (handle_id);
  int sig = h ? (int) h->sig : -1;
  jit_unlock ();
  return sig;
}

/* ── syms_of ──────────────────────────────────────────────────────── */

void
syms_of_cmacs_cintrospect_jit (void)
{
  /* Dedicated error condition. */
  DEFSYM (Qcmacs_cintrospect_compile_error, "cmacs-cintrospect-compile-error");
  Fput (Qcmacs_cintrospect_compile_error, Qerror_conditions,
        list2 (Qcmacs_cintrospect_compile_error, Qerror));
  Fput (Qcmacs_cintrospect_compile_error, Qerror_message,
        build_string ("cmacs-cintrospect: C compilation failed"));

  defsubr (&Scmacs_c_compile);
  defsubr (&Scmacs_c_call);
  defsubr (&Scmacs_c_handle_info);
  defsubr (&Scmacs_c_handle_dispose);
}

#endif /* HAVE_CMACS_CINTROSPECT */
