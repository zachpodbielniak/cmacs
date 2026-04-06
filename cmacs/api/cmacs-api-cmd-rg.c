/* cmacs-api-cmd-rg.c �� ripgrep integration for cmacsgi
 *
 * Runs ripgrep and displays results in an Emacs grep-mode buffer.
 * Results are clickable: RET or mouse-2 jumps to file:line.
 * Integrates with next-error / prev-error for keyboard navigation.
 *
 * Subcommands:
 *   rg search [-i] [-w] PATTERN [DIR]   full-text search (default)
 *   rg files  [-i] [-w] PATTERN [DIR]   list matching files only
 *   rg type   [-i] [-w] TYPE PATTERN [DIR]   filter by file type
 *
 * rg must be on PATH.  Install via your package manager:
 *   dnf install ripgrep   (Fedora)
 *   apt install ripgrep   (Debian/Ubuntu)
 */

#include "cmacs-api.h"

/* ── Helpers ──────────────────────────────────────────────────────── */

/*
 * Build the core rg flags string from parsed options.
 * Caller must g_free() the returned string.
 */
static gchar *
rg_build_flags(gboolean case_insensitive, gboolean whole_word)
{
    GString *flags;

    flags = g_string_new("--color=never --line-number --no-heading");

    if (case_insensitive)
        g_string_append(flags, " --ignore-case");

    if (whole_word)
        g_string_append(flags, " --word-regexp");

    return g_string_free(flags, FALSE);
}

/*
 * Parse common flags (-i, -w) from argv starting at *pos.
 * Advances *pos past any flags it consumes.
 */
static void
rg_parse_flags(gint argc, gchar **argv, gint *pos,
               gboolean *case_insensitive, gboolean *whole_word)
{
    *case_insensitive = FALSE;
    *whole_word       = FALSE;

    while (*pos < argc && argv[*pos][0] == '-')
    {
        if (strcmp(argv[*pos], "-i") == 0)
        {
            *case_insensitive = TRUE;
            (*pos)++;
        }
        else if (strcmp(argv[*pos], "-w") == 0)
        {
            *whole_word = TRUE;
            (*pos)++;
        }
        else if (strcmp(argv[*pos], "--") == 0)
        {
            (*pos)++;
            break;
        }
        else
            break;
    }
}

/*
 * Launch ripgrep via compilation-start in grep-mode.
 * cmd is the full shell command string (already built).
 * dir is the working directory (NULL = default-directory).
 * Caller must g_free() both cmd and dir.
 */
static gint
rg_run_grep(CmacsApiTransport *transport,
            const gchar       *cmd,
            const gchar       *dir)
{
    gchar *esc_cmd, *esc_dir, *elisp;
    gint   rc;

    esc_cmd = cmacs_api_lisp_escape(cmd);

    if (dir != NULL)
    {
        esc_dir = cmacs_api_lisp_escape(dir);
        elisp = g_strdup_printf(
            "(let ((default-directory \"%s\"))"
            " (compilation-start \"%s\" 'grep-mode"
            "  (lambda (_) \"*rg*\")))",
            esc_dir, esc_cmd);
        g_free(esc_dir);
    }
    else
    {
        elisp = g_strdup_printf(
            "(compilation-start \"%s\" 'grep-mode"
            " (lambda (_) \"*rg*\"))",
            esc_cmd);
    }

    g_free(esc_cmd);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

/* ── Subcommand handlers ──────────────────────────────────────────── */

/*
 * rg search [-i] [-w] PATTERN [DIR]
 *
 * Runs: rg --color=never --line-number --no-heading [flags] PATTERN [DIR]
 * Opens results in *rg* buffer in grep-mode.
 */
static gint
rg_search(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gint      pos;
    gboolean  icase, whole_word;
    gchar    *flags, *esc_pat, *cmd;
    const gchar *pattern, *dir;
    gint      rc;

    pos = 3; /* argv[0]="cmacsgi" argv[1]="rg" argv[2]="search" argv[3]=first arg */
    rg_parse_flags(argc, argv, &pos, &icase, &whole_word);

    if (pos >= argc)
    {
        fprintf(stderr, "cmacsgi rg search: missing pattern\n");
        return 1;
    }

    pattern = argv[pos++];
    dir     = (pos < argc) ? argv[pos] : NULL;

    flags   = rg_build_flags(icase, whole_word);
    esc_pat = cmacs_api_lisp_escape(pattern);

    if (dir != NULL)
    {
        gchar *esc_dir = cmacs_api_lisp_escape(dir);
        cmd = g_strdup_printf("rg %s %s %s", flags, esc_pat, esc_dir);
        g_free(esc_dir);
    }
    else
    {
        cmd = g_strdup_printf("rg %s %s .", flags, esc_pat);
    }

    g_free(flags);
    g_free(esc_pat);

    rc = rg_run_grep(transport, cmd, dir);
    g_free(cmd);
    return rc;
}

/*
 * rg files [-i] [-w] PATTERN [DIR]
 *
 * Runs: rg --files-with-matches [flags] PATTERN [DIR]
 * Opens matching file list in *rg* buffer.
 */
static gint
rg_files(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gint      pos;
    gboolean  icase, whole_word;
    gchar    *flags, *esc_pat, *cmd;
    const gchar *pattern, *dir;
    gint      rc;

    pos = 3;
    rg_parse_flags(argc, argv, &pos, &icase, &whole_word);

    if (pos >= argc)
    {
        fprintf(stderr, "cmacsgi rg files: missing pattern\n");
        return 1;
    }

    pattern = argv[pos++];
    dir     = (pos < argc) ? argv[pos] : NULL;

    flags   = rg_build_flags(icase, whole_word);
    esc_pat = cmacs_api_lisp_escape(pattern);

    /*
     * --files-with-matches (-l) outputs file paths only.
     * We still use --line-number and --no-heading from the base flags
     * but override with -l which suppresses line numbers.
     */
    if (dir != NULL)
    {
        gchar *esc_dir = cmacs_api_lisp_escape(dir);
        cmd = g_strdup_printf(
            "rg --color=never --files-with-matches %s%s %s %s",
            icase ? "--ignore-case " : "",
            whole_word ? "--word-regexp " : "",
            esc_pat, esc_dir);
        g_free(esc_dir);
    }
    else
    {
        cmd = g_strdup_printf(
            "rg --color=never --files-with-matches %s%s %s .",
            icase ? "--ignore-case " : "",
            whole_word ? "--word-regexp " : "",
            esc_pat);
    }

    g_free(flags);
    g_free(esc_pat);

    rc = rg_run_grep(transport, cmd, dir);
    g_free(cmd);
    return rc;
}

/*
 * rg type [-i] [-w] TYPE PATTERN [DIR]
 *
 * Runs: rg --type TYPE [flags] PATTERN [DIR]
 * TYPE is a ripgrep file type: c, rust, py, js, html, etc.
 * See `rg --type-list` for all supported types.
 */
static gint
rg_type(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gint      pos;
    gboolean  icase, whole_word;
    gchar    *flags, *esc_pat, *esc_type, *cmd;
    const gchar *type, *pattern, *dir;
    gint      rc;

    pos = 3;
    rg_parse_flags(argc, argv, &pos, &icase, &whole_word);

    if (pos + 1 >= argc)
    {
        fprintf(stderr,
                "cmacsgi rg type: usage: rg type [-i] [-w] TYPE PATTERN [DIR]\n");
        return 1;
    }

    type    = argv[pos++];
    pattern = argv[pos++];
    dir     = (pos < argc) ? argv[pos] : NULL;

    flags    = rg_build_flags(icase, whole_word);
    esc_type = cmacs_api_lisp_escape(type);
    esc_pat  = cmacs_api_lisp_escape(pattern);

    if (dir != NULL)
    {
        gchar *esc_dir = cmacs_api_lisp_escape(dir);
        cmd = g_strdup_printf(
            "rg %s --type %s %s %s",
            flags, esc_type, esc_pat, esc_dir);
        g_free(esc_dir);
    }
    else
    {
        cmd = g_strdup_printf(
            "rg %s --type %s %s .",
            flags, esc_type, esc_pat);
    }

    g_free(flags);
    g_free(esc_type);
    g_free(esc_pat);

    rc = rg_run_grep(transport, cmd, dir);
    g_free(cmd);
    return rc;
}

/* ── Dispatch table ───────────────────────────────────────────────── */

static const CmacsApiSubcmd rg_subcmds[] = {
    { "search", rg_search,
      "rg search [-i] [-w] PATTERN [DIR]",
      "full-text ripgrep search, results in *rg* buffer" },
    { "files",  rg_files,
      "rg files [-i] [-w] PATTERN [DIR]",
      "list files containing PATTERN" },
    { "type",   rg_type,
      "rg type [-i] [-w] TYPE PATTERN [DIR]",
      "ripgrep filtered by file type (c, rust, py, ...)" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_rg(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    /*
     * Bare `cmacsgi rg PATTERN [DIR]` (no subcommand) is a shortcut
     * for `cmacsgi rg search PATTERN [DIR]`.  Detect this by checking
     * whether argv[2] is a known subcommand name.
     */
    if (argc >= 3)
    {
        const gchar *first = argv[2];

        if (strcmp(first, "search") != 0 &&
            strcmp(first, "files")  != 0 &&
            strcmp(first, "type")   != 0 &&
            strcmp(first, "--help") != 0 &&
            strcmp(first, "-h")     != 0)
        {
            /*
             * Treat as bare `rg search` call.  Shift argv so that
             * rg_search sees argv[3] as the first flag/pattern.
             * We do this by inserting a synthetic "search" into the
             * dispatch by building a temporary argv with it spliced in.
             */
            gint      new_argc;
            gchar   **new_argv;
            gint      i;
            gint      rc;

            new_argc = argc + 1;
            new_argv = g_new(gchar *, new_argc + 1);
            new_argv[0] = argv[0]; /* cmacsgi */
            new_argv[1] = argv[1]; /* rg      */
            new_argv[2] = (gchar *)"search";
            for (i = 2; i < argc; i++)
                new_argv[i + 1] = argv[i];
            new_argv[new_argc] = NULL;

            rc = rg_search(transport, new_argc, new_argv);
            g_free(new_argv);
            return rc;
        }
    }

    return cmacs_api_dispatch_group("rg", rg_subcmds,
                                    transport, argc, argv, 2);
}
