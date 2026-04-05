/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-search.c — search/replace subcommands for cmacsgi
 *
 * Subcommands:
 *   search [-b BUF] [-r] [-c] PATTERN   search for pattern
 *   replace [-b BUF] [-r] PATTERN REPL   replace all occurrences
 *   occur [-b BUF] PATTERN               list matching lines (grep-style)
 */

#include "cmacs-api.h"

/* ── Helpers ──────────────────────────────────────────────────────── */

static gchar *
wrap_with_buffer(const gchar *buf, const gchar *body)
{
    gchar *esc, *result;

    if (buf == NULL)
        return g_strdup_printf("(progn %s)", body);

    esc = cmacs_api_lisp_escape(buf);
    result = g_strdup_printf(
        "(with-current-buffer \"%s\" %s)", esc, body);
    g_free(esc);
    return result;
}

/* ── Subcommand handlers ──────────────────────────────────────────── */

gint
cmd_search(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gboolean use_regex, count_only;
    gint i;
    const gchar *pattern;
    gchar *esc_pat, *body, *elisp;
    gint rc;
    const gchar *search_fn;

    buf = NULL;
    use_regex = FALSE;
    count_only = FALSE;

    i = 2;
    while (i < argc && argv[i][0] == '-')
    {
        if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
        {
            buf = argv[i + 1];
            i += 2;
        }
        else if (strcmp(argv[i], "-r") == 0)
        {
            use_regex = TRUE;
            i++;
        }
        else if (strcmp(argv[i], "-c") == 0)
        {
            count_only = TRUE;
            i++;
        }
        else if (strcmp(argv[i], "--") == 0)
        {
            i++;
            break;
        }
        else
            break;
    }

    if (i >= argc)
    {
        fprintf(stderr, "cmacsgi search: missing pattern\n");
        return 1;
    }

    pattern = argv[i];
    esc_pat = cmacs_api_lisp_escape(pattern);
    search_fn = use_regex ? "re-search-forward" : "search-forward";

    if (count_only)
    {
        body = g_strdup_printf(
            "(let ((n 0))"
            " (save-excursion"
            "  (goto-char (point-min))"
            "  (while (%s \"%s\" nil t) (setq n (1+ n))))"
            " (number-to-string n))",
            search_fn, esc_pat);
    }
    else
    {
        body = g_strdup_printf(
            "(save-excursion"
            " (goto-char (point-min))"
            " (if (%s \"%s\" nil t)"
            "   (format \"%%d:%%d:%%s\""
            "     (line-number-at-pos (match-beginning 0))"
            "     (- (match-beginning 0)"
            "        (line-beginning-position"
            "          (line-number-at-pos (match-beginning 0))))"
            "     (match-string 0))"
            "   \"no match\"))",
            search_fn, esc_pat);
    }

    g_free(esc_pat);
    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_replace(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gboolean use_regex;
    gint i;
    const gchar *pattern, *repl;
    gchar *esc_pat, *esc_repl, *body, *elisp;
    gint rc;
    const gchar *search_fn;

    buf = NULL;
    use_regex = FALSE;

    i = 2;
    while (i < argc && argv[i][0] == '-')
    {
        if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
        {
            buf = argv[i + 1];
            i += 2;
        }
        else if (strcmp(argv[i], "-r") == 0)
        {
            use_regex = TRUE;
            i++;
        }
        else if (strcmp(argv[i], "--") == 0)
        {
            i++;
            break;
        }
        else
            break;
    }

    if (i + 1 >= argc)
    {
        fprintf(stderr,
                "cmacsgi replace: usage: replace [-b BUF] [-r] PATTERN REPL\n");
        return 1;
    }

    pattern = argv[i];
    repl    = argv[i + 1];
    esc_pat  = cmacs_api_lisp_escape(pattern);
    esc_repl = cmacs_api_lisp_escape(repl);
    search_fn = use_regex ? "re-search-forward" : "search-forward";

    body = g_strdup_printf(
        "(let ((n 0))"
        " (save-excursion"
        "  (goto-char (point-min))"
        "  (while (%s \"%s\" nil t)"
        "   (replace-match \"%s\" %s)"
        "   (setq n (1+ n))))"
        " (number-to-string n))",
        search_fn, esc_pat, esc_repl,
        use_regex ? "nil" : "t");

    g_free(esc_pat);
    g_free(esc_repl);
    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_occur(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i;
    const gchar *pattern;
    gchar *esc_pat, *body, *elisp;
    gint rc;

    buf = NULL;

    i = 2;
    while (i < argc && argv[i][0] == '-')
    {
        if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
        {
            buf = argv[i + 1];
            i += 2;
        }
        else if (strcmp(argv[i], "--") == 0)
        {
            i++;
            break;
        }
        else
            break;
    }

    if (i >= argc)
    {
        fprintf(stderr, "cmacsgi occur: missing pattern\n");
        return 1;
    }

    pattern = argv[i];
    esc_pat = cmacs_api_lisp_escape(pattern);

    body = g_strdup_printf(
        "(let (lines)"
        " (save-excursion"
        "  (goto-char (point-min))"
        "  (while (re-search-forward \"%s\" nil t)"
        "   (push (format \"%%d:%%s\""
        "           (line-number-at-pos (match-beginning 0))"
        "           (buffer-substring"
        "             (line-beginning-position)"
        "             (line-end-position)))"
        "         lines)"
        "   (forward-line 1)))"
        " (mapconcat #'identity (nreverse lines) \"\\n\"))",
        esc_pat);

    g_free(esc_pat);
    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}
