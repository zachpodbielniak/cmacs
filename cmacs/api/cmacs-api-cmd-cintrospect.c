/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-cmd-cintrospect.c --- C runtime introspection and
 * hot-patching subcommands for cmacsgi.
 *
 * Group:  c
 *
 * Read-only introspection (always built):
 *   c list KIND [-g GLOB] [-n N]    list symbol|defun|object entities
 *   c symbol NAME                   plist for a C symbol
 *   c type NAME                     plist for a C type (struct/union/enum)
 *   c source NAME                   (file . line) for a C function
 *   c addr 0xADDR                   resolve runtime address to (file line fn)
 *   c source-to-addr FILE LINE      reverse lookup
 *   c objects                       list loaded ELF objects
 *   c defuns [-g GLOB] [-n N]       list Lisp_Subr DEFUNs
 *   c defun-info SYM                plist for a DEFUN
 *   c stack [-d N]                  C stack trace
 *
 * Symbol read/write:
 *   c get NAME [TYPE]               read C global value
 *   c set NAME VALUE [TYPE]         write C global value
 *
 * JIT (libgccjit subprocess):
 *   c compile NAME FILE [-s SIG]    compile FILE, return handle
 *   c call HANDLE [ARG...]          invoke a JIT handle
 *   c handle HANDLE                 plist for a handle
 *   c handle-dispose HANDLE         dlclose + cleanup
 *
 * cpatch (gated by --enable-cmacs-cpatch at the editor side; the
 *  handlers always exist on the client and probe `fboundp' first):
 *   c patch SYM FN-NAME             swap DEFUN to point at FN-NAME's addr
 *   c unpatch SYM                   restore original
 *   c patches                       list current patches
 *   c unpatch-all                   panic button
 */

#include "cmacs-api.h"

/* Wrap ELISP in an `fboundp' guard for the cpatch DEFUNs.  Prints a
   friendly message and returns 1 if the build doesn't have cpatch.  */
static gint
eval_cpatch_guarded (CmacsApiTransport *transport, const gchar *elisp,
                     const gchar *probe)
{
    gchar *wrapped;
    gint rc;

    wrapped = g_strdup_printf (
        "(if (fboundp '%s) %s"
        " \"cpatch not enabled in this build"
        " (configure --enable-cmacs-cpatch)\")",
        probe, elisp);
    rc = cmacs_api_eval_print (transport, wrapped);
    g_free (wrapped);
    return rc;
}

/* Slurp FILE into a freshly-allocated, NUL-terminated buffer.
   Returns NULL and prints to stderr on error.  Caller g_free()s.  */
static gchar *
slurp_file (const gchar *path)
{
    gchar *contents = NULL;
    gsize len = 0;
    GError *err = NULL;

    if (!g_file_get_contents (path, &contents, &len, &err))
    {
        fprintf (stderr, "cmacsgi c: cannot read '%s': %s\n",
                 path, err ? err->message : "unknown error");
        if (err) g_error_free (err);
        return NULL;
    }
    return contents;
}

/* ── Read-only introspection ─────────────────────────────────────── */

static gint
c_list (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *kind = NULL;
    const gchar *glob = NULL;
    const gchar *limit = NULL;
    gchar *escaped_glob;
    gchar *elisp;
    gint rc, i;

    for (i = 3; i < argc; i++)
    {
        if (strcmp (argv[i], "-g") == 0 && i + 1 < argc)
            glob = argv[++i];
        else if (strcmp (argv[i], "-n") == 0 && i + 1 < argc)
            limit = argv[++i];
        else if (kind == NULL)
            kind = argv[i];
    }

    if (kind == NULL)
    {
        fprintf (stderr, "cmacsgi c list: missing KIND"
                 " (one of: symbol defun type object)\n");
        return 1;
    }

    escaped_glob = glob ? cmacs_api_lisp_escape (glob) : NULL;
    elisp = g_strdup_printf (
        "(cmacs-c-list '%s %s%s%s %s)",
        kind,
        escaped_glob ? "\"" : "",
        escaped_glob ? escaped_glob : "nil",
        escaped_glob ? "\"" : "",
        limit ? limit : "nil");
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped_glob);
    return rc;
}

static gint
c_symbol (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c symbol: missing NAME\n");
        return 1;
    }
    escaped = cmacs_api_lisp_escape (argv[3]);
    elisp = g_strdup_printf ("(cmacs-c-symbol-info \"%s\")", escaped);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped);
    return rc;
}

static gint
c_type (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c type: missing NAME\n");
        return 1;
    }
    escaped = cmacs_api_lisp_escape (argv[3]);
    elisp = g_strdup_printf ("(cmacs-c-type-info \"%s\")", escaped);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped);
    return rc;
}

static gint
c_source (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c source: missing NAME\n");
        return 1;
    }
    escaped = cmacs_api_lisp_escape (argv[3]);
    elisp = g_strdup_printf ("(cmacs-c-function-source \"%s\")", escaped);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped);
    return rc;
}

static gint
c_addr (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c addr: missing 0xADDR\n");
        return 1;
    }
    /* argv[3] passes through untouched: 0x... reads as an integer in
       elisp, decimal also fine.  Refuse anything weirder. */
    if (strchr (argv[3], '"') || strchr (argv[3], '(')
        || strchr (argv[3], ' '))
    {
        fprintf (stderr, "cmacsgi c addr: bad address literal\n");
        return 1;
    }
    elisp = g_strdup_printf ("(cmacs-c-addr-to-source %s)", argv[3]);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
c_source_to_addr (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 5)
    {
        fprintf (stderr, "cmacsgi c source-to-addr: usage:"
                 " source-to-addr FILE LINE\n");
        return 1;
    }
    escaped = cmacs_api_lisp_escape (argv[3]);
    elisp = g_strdup_printf (
        "(let ((a (cmacs-c-source-to-addr \"%s\" %s)))"
        " (and a (format \"0x%%x\" a)))",
        escaped, argv[4]);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped);
    return rc;
}

static gint
c_objects (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void) argc; (void) argv;
    return cmacs_api_eval_print (transport, "(cmacs-c-list-objects)");
}

static gint
c_defuns (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *glob = NULL;
    const gchar *limit = NULL;
    gchar *escaped_glob;
    gchar *elisp;
    gint rc, i;

    for (i = 3; i < argc; i++)
    {
        if (strcmp (argv[i], "-g") == 0 && i + 1 < argc)
            glob = argv[++i];
        else if (strcmp (argv[i], "-n") == 0 && i + 1 < argc)
            limit = argv[++i];
    }

    escaped_glob = glob ? cmacs_api_lisp_escape (glob) : NULL;
    elisp = g_strdup_printf (
        "(cmacs-c-list-defuns %s%s%s %s)",
        escaped_glob ? "\"" : "",
        escaped_glob ? escaped_glob : "nil",
        escaped_glob ? "\"" : "",
        limit ? limit : "nil");
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped_glob);
    return rc;
}

static gint
c_defun_info (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c defun-info: missing SYM\n");
        return 1;
    }
    escaped = cmacs_api_lisp_escape (argv[3]);
    /* Pass as a string; the DEFUN auto-interns. */
    elisp = g_strdup_printf ("(cmacs-c-defun-info \"%s\")", escaped);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped);
    return rc;
}

static gint
c_stack (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *depth = NULL;
    gchar *elisp;
    gint rc, i;

    for (i = 3; i < argc; i++)
        if (strcmp (argv[i], "-d") == 0 && i + 1 < argc)
            depth = argv[++i];

    elisp = g_strdup_printf ("(cmacs-c-stack-trace %s)",
                             depth ? depth : "nil");
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

/* ── Symbol read/write ───────────────────────────────────────────── */

static gint
c_get (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    const gchar *type = "auto";
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c get: missing NAME\n");
        return 1;
    }
    if (argc >= 5)
        type = argv[4];

    escaped = cmacs_api_lisp_escape (argv[3]);
    elisp = g_strdup_printf ("(cmacs-c-symbol-value \"%s\" '%s)",
                             escaped, type);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped);
    return rc;
}

static gint
c_set (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped_name, *quoted_value, *elisp;
    const gchar *type = "auto";
    gint rc;

    if (argc < 5)
    {
        fprintf (stderr, "cmacsgi c set: usage: set NAME VALUE [TYPE]\n");
        return 1;
    }
    if (argc >= 6)
        type = argv[5];

    escaped_name = cmacs_api_lisp_escape (argv[3]);
    quoted_value = cmacs_api_lisp_quote (argv[4]);
    elisp = g_strdup_printf (
        "(cmacs-c-symbol-set-value \"%s\" %s '%s)",
        escaped_name, quoted_value, type);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped_name);
    g_free (quoted_value);
    return rc;
}

/* ── JIT ─────────────────────────────────────────────────────────── */

static gint
c_compile (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *func_name = NULL;
    const gchar *file = NULL;
    const gchar *sig = NULL;
    gchar *source, *escaped_src, *escaped_func, *escaped_sig, *elisp;
    gint rc, i;

    for (i = 3; i < argc; i++)
    {
        if (strcmp (argv[i], "-s") == 0 && i + 1 < argc)
            sig = argv[++i];
        else if (func_name == NULL)
            func_name = argv[i];
        else if (file == NULL)
            file = argv[i];
    }

    if (func_name == NULL || file == NULL)
    {
        fprintf (stderr, "cmacsgi c compile: usage:"
                 " compile [-s SIG] FUNC-NAME FILE.c\n");
        return 1;
    }

    source = slurp_file (file);
    if (source == NULL)
        return 1;

    escaped_src = cmacs_api_lisp_escape (source);
    escaped_func = cmacs_api_lisp_escape (func_name);
    escaped_sig = sig ? cmacs_api_lisp_escape (sig) : NULL;

    if (escaped_sig)
        elisp = g_strdup_printf (
            "(cmacs-c-compile \"%s\" \"%s\" \"%s\")",
            escaped_src, escaped_func, escaped_sig);
    else
        elisp = g_strdup_printf (
            "(cmacs-c-compile \"%s\" \"%s\")",
            escaped_src, escaped_func);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_free (escaped_src);
    g_free (escaped_func);
    g_free (escaped_sig);
    g_free (source);
    return rc;
}

static gint
c_call (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GString *args_str;
    gchar *quoted, *elisp;
    gint rc, i;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c call: missing HANDLE\n");
        return 1;
    }

    args_str = g_string_new ("");
    for (i = 4; i < argc; i++)
    {
        quoted = cmacs_api_lisp_quote (argv[i]);
        g_string_append_c (args_str, ' ');
        g_string_append (args_str, quoted);
        g_free (quoted);
    }

    elisp = g_strdup_printf ("(cmacs-c-call %s%s)",
                             argv[3], args_str->str);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    g_string_free (args_str, TRUE);
    return rc;
}

static gint
c_handle (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c handle: missing HANDLE\n");
        return 1;
    }
    elisp = g_strdup_printf ("(cmacs-c-handle-info %s)", argv[3]);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
c_handle_dispose (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c handle-dispose: missing HANDLE\n");
        return 1;
    }
    elisp = g_strdup_printf ("(cmacs-c-handle-dispose %s)", argv[3]);
    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

/* ── cpatch (probed) ─────────────────────────────────────────────── */

static gint
c_patch (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped_sym, *escaped_fn, *body;
    gint rc;

    if (argc < 5)
    {
        fprintf (stderr, "cmacsgi c patch: usage: patch SYM FN-NAME\n");
        return 1;
    }
    escaped_sym = cmacs_api_lisp_escape (argv[3]);
    escaped_fn  = cmacs_api_lisp_escape (argv[4]);
    /* Resolve FN-NAME -> addr and patch in a single eval to avoid
       any TOCTOU between lookup and swap.  */
    body = g_strdup_printf (
        "(let* ((info (cmacs-c-symbol-info \"%s\"))"
        "       (addr (and info (plist-get info :addr))))"
        " (if (not addr)"
        "   (error \"cmacsgi c patch: function '%s' not found\")"
        "  (cmacs-c-patch-defun (intern \"%s\") addr)))",
        escaped_fn, escaped_fn, escaped_sym);
    g_free (escaped_sym);
    g_free (escaped_fn);

    rc = eval_cpatch_guarded (transport, body, "cmacs-c-patch-defun");
    g_free (body);
    return rc;
}

static gint
c_unpatch (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *body;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi c unpatch: missing SYM\n");
        return 1;
    }
    escaped = cmacs_api_lisp_escape (argv[3]);
    body = g_strdup_printf ("(cmacs-c-unpatch-defun (intern \"%s\"))",
                            escaped);
    rc = eval_cpatch_guarded (transport, body, "cmacs-c-unpatch-defun");
    g_free (body);
    g_free (escaped);
    return rc;
}

static gint
c_patches (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void) argc; (void) argv;
    return eval_cpatch_guarded (transport, "(cmacs-c-patch-list)",
                                "cmacs-c-patch-list");
}

static gint
c_unpatch_all (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void) argc; (void) argv;
    return eval_cpatch_guarded (transport, "(cmacs-c-unpatch-all)",
                                "cmacs-c-unpatch-all");
}

/* ── Dispatch table ──────────────────────────────────────────────── */

static const CmacsApiSubcmd c_subcmds[] = {
    /* read-only introspection */
    { "list",        c_list,
      "list KIND [-g GLOB] [-n N]",
      "list C entities (KIND: symbol|defun|object)" },
    { "symbol",      c_symbol,
      "symbol NAME",
      "plist for a C symbol (kind, addr, size, file, line)" },
    { "type",        c_type,
      "type NAME",
      "plist for a C type (struct/union/enum layout)" },
    { "source",      c_source,
      "source NAME",
      "(file . line) for a C function" },
    { "addr",        c_addr,
      "addr 0xADDR",
      "resolve runtime address to (file line function)" },
    { "source-to-addr", c_source_to_addr,
      "source-to-addr FILE LINE",
      "reverse lookup: file:line -> 0xADDR" },
    { "objects",     c_objects,
      "objects",
      "list loaded ELF objects with DWARF availability" },
    { "defuns",      c_defuns,
      "defuns [-g GLOB] [-n N]",
      "list every Lisp-callable C primitive (DEFUN)" },
    { "defun-info",  c_defun_info,
      "defun-info SYM",
      "plist for a DEFUN (arity, fn-addr, source)" },
    { "stack",       c_stack,
      "stack [-d N]",
      "C stack trace via libdw (default depth 64)" },

    /* symbol read/write */
    { "get",         c_get,
      "get NAME [TYPE]",
      "read C global value (TYPE: auto|int|str|lisp|hex|pointer)" },
    { "set",         c_set,
      "set NAME VALUE [TYPE]",
      "write C global value (TYPE: auto|int|str|lisp|hex)" },

    /* JIT */
    { "compile",     c_compile,
      "compile [-s SIG] FUNC-NAME FILE.c",
      "JIT-compile FILE.c, return handle id" },
    { "call",        c_call,
      "call HANDLE [ARG...]",
      "invoke a JIT handle, print result" },
    { "handle",      c_handle,
      "handle HANDLE",
      "plist for a JIT handle" },
    { "handle-dispose", c_handle_dispose,
      "handle-dispose HANDLE",
      "dlclose handle, remove temp files" },

    /* cpatch */
    { "patch",       c_patch,
      "patch SYM FN-NAME",
      "swap DEFUN to call FN-NAME (cpatch only)" },
    { "unpatch",     c_unpatch,
      "unpatch SYM",
      "restore DEFUN's original pointer" },
    { "patches",     c_patches,
      "patches",
      "list current patches" },
    { "unpatch-all", c_unpatch_all,
      "unpatch-all",
      "restore every patched DEFUN (panic button)" },

    { NULL, NULL, NULL, NULL }
};

gint
cmd_c (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_api_dispatch_group ("c", c_subcmds,
                                     transport, argc, argv, 2);
}
