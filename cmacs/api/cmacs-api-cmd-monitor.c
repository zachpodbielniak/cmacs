/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-cmd-monitor.c --- monitor management subcommands for cmacsgi
 *
 * Subcommands:
 *   monitor list                    list connected monitors
 *   monitor info NAME               detailed monitor info
 *   monitor modes NAME              available resolutions
 *   monitor set-mode NAME WxH[@R]   set resolution
 *   monitor position NAME           get position
 *   monitor set-position NAME X Y   set position
 *   monitor enable NAME             enable monitor
 *   monitor disable NAME            disable monitor
 *   monitor scale NAME [FACTOR]     get/set scale factor
 *   monitor transform NAME [VALUE]  get/set transform
 */

#include "cmacs-api.h"

/* ── Helpers ─────────────────────────────────────────────────────────── */

/* Build elisp to resolve a monitor by name.  Returns a g_strdup'd
   string like: (gowl-find-monitor "eDP-1")
   Caller must g_free. */
static gchar *
mon_ref (const gchar *name)
{
    gchar *escaped = cmacs_api_lisp_escape (name);
    gchar *ref = g_strdup_printf ("(gowl-find-monitor \"%s\")", escaped);
    g_free (escaped);
    return ref;
}

/* ── Handlers ────────────────────────────────────────────────────────── */

static gint
mon_list (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;

    return cmacs_api_eval_print (transport,
        "(mapconcat"
        " (lambda (m)"
        "   (let* ((info (gowl-monitor-info m))"
        "          (name (cdr (assq 'name info)))"
        "          (geo (cdr (assq 'geometry info)))"
        "          (mode (gowl-monitor-current-mode m))"
        "          (sc (gowl-monitor-scale m))"
        "          (en (gowl-monitor-enabled-p m))"
        "          (xf (gowl-monitor-transform m)))"
        "     (format \"%-12s %dx%d@%dHz  pos:%d,%d  scale:%.1f  %s  %s\""
        "             name"
        "             (if mode (nth 0 mode) 0)"
        "             (if mode (nth 1 mode) 0)"
        "             (if mode (/ (nth 2 mode) 1000) 0)"
        "             (nth 0 geo) (nth 1 geo)"
        "             sc"
        "             (if en \"enabled\" \"disabled\")"
        "             xf)))"
        " (gowl-list-monitors) \"\\n\")");
}

static gint
mon_info (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor info: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (let ((info (gowl-monitor-info m)))"
        "     (mapconcat"
        "      (lambda (kv) (format \"%%s: %%S\" (car kv) (cdr kv)))"
        "      info \"\\n\"))"
        "   \"monitor not found\"))",
        ref);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_modes (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor modes: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (let ((cur (gowl-monitor-current-mode m)))"
        "     (mapconcat"
        "      (lambda (mode)"
        "        (format \"%%s%%dx%%d@%%dHz\""
        "                (if (and cur (equal mode cur)) \"* \" \"  \")"
        "                (nth 0 mode) (nth 1 mode)"
        "                (/ (nth 2 mode) 1000)))"
        "      (gowl-monitor-modes m) \"\\n\"))"
        "   \"monitor not found\"))",
        ref);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_set_mode (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint w, h, rate_mhz;
    gint rc;
    gchar *at;

    if (argc < 5)
    {
        fprintf (stderr,
                 "cmacsgi monitor set-mode: usage: "
                 "monitor set-mode NAME WxH[@RATE]\n");
        return 1;
    }

    /* Parse WxH[@RATE] */
    if (sscanf (argv[4], "%dx%d", &w, &h) != 2)
    {
        fprintf (stderr, "cmacsgi monitor set-mode: "
                 "invalid format '%s' (expected WxH[@RATE])\n", argv[4]);
        return 1;
    }

    at = strchr (argv[4], '@');
    if (at != NULL)
        rate_mhz = atoi (at + 1) * 1000;
    else
        rate_mhz = 0;

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (if (gowl-set-monitor-mode %d %d %d m)"
        "     \"ok\" \"failed to set mode\")"
        "   \"monitor not found\"))",
        ref, w, h, rate_mhz);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_position (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor position: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (let ((pos (gowl-monitor-position m)))"
        "     (format \"%%d %%d\" (car pos) (cdr pos)))"
        "   \"monitor not found\"))",
        ref);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_set_position (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint x, y, rc;

    if (argc < 6)
    {
        fprintf (stderr,
                 "cmacsgi monitor set-position: usage: "
                 "monitor set-position NAME X Y\n");
        return 1;
    }

    x = atoi (argv[4]);
    y = atoi (argv[5]);

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (if (gowl-set-monitor-position %d %d m)"
        "     \"ok\" \"failed to set position\")"
        "   \"monitor not found\"))",
        ref, x, y);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_enable (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor enable: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (if (gowl-set-monitor-enabled t m)"
        "     \"ok\" \"failed to enable\")"
        "   \"monitor not found\"))",
        ref);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_disable (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor disable: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);
    elisp = g_strdup_printf (
        "(let ((m %s))"
        " (if m"
        "   (if (gowl-set-monitor-enabled nil m)"
        "     \"ok\" \"failed to disable\")"
        "   \"monitor not found\"))",
        ref);
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_scale (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor scale: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);

    if (argc >= 5)
    {
        /* Set scale */
        gdouble scale = g_ascii_strtod (argv[4], NULL);
        elisp = g_strdup_printf (
            "(let ((m %s))"
            " (if m"
            "   (if (gowl-set-monitor-scale %.2f m)"
            "     \"ok\" \"failed to set scale\")"
            "   \"monitor not found\"))",
            ref, scale);
    }
    else
    {
        /* Get scale */
        elisp = g_strdup_printf (
            "(let ((m %s))"
            " (if m"
            "   (format \"%%.2f\" (gowl-monitor-scale m))"
            "   \"monitor not found\"))",
            ref);
    }
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

static gint
mon_transform (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *ref, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf (stderr, "cmacsgi monitor transform: missing NAME\n");
        return 1;
    }

    ref = mon_ref (argv[3]);

    if (argc >= 5)
    {
        /* Set transform — accept name or number */
        gchar *escaped = cmacs_api_lisp_escape (argv[4]);
        elisp = g_strdup_printf (
            "(let ((m %s))"
            " (if m"
            "   (let ((xf (if (string-match-p \"^[0-7]$\" \"%s\")"
            "                (string-to-number \"%s\")"
            "                (intern \"%s\"))))"
            "     (if (gowl-set-monitor-transform xf m)"
            "       \"ok\" \"failed to set transform\"))"
            "   \"monitor not found\"))",
            ref, escaped, escaped, escaped);
        g_free (escaped);
    }
    else
    {
        /* Get transform */
        elisp = g_strdup_printf (
            "(let ((m %s))"
            " (if m"
            "   (symbol-name (gowl-monitor-transform m))"
            "   \"monitor not found\"))",
            ref);
    }
    g_free (ref);

    rc = cmacs_api_eval_print (transport, elisp);
    g_free (elisp);
    return rc;
}

/* ── Dispatch table ──────────────────────────────────────────────────── */

static const CmacsApiSubcmd monitor_subcmds[] = {
    { "list",         mon_list,
      "monitor list",                     "list connected monitors" },
    { "info",         mon_info,
      "monitor info NAME",                "detailed monitor info" },
    { "modes",        mon_modes,
      "monitor modes NAME",               "available resolutions" },
    { "set-mode",     mon_set_mode,
      "monitor set-mode NAME WxH[@RATE]", "set resolution" },
    { "position",     mon_position,
      "monitor position NAME",            "get position" },
    { "set-position", mon_set_position,
      "monitor set-position NAME X Y",    "set position in layout" },
    { "enable",       mon_enable,
      "monitor enable NAME",              "enable a monitor" },
    { "disable",      mon_disable,
      "monitor disable NAME",             "disable a monitor" },
    { "scale",        mon_scale,
      "monitor scale NAME [FACTOR]",      "get/set scale factor" },
    { "transform",    mon_transform,
      "monitor transform NAME [VALUE]",   "get/set transform" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_monitor (CmacsApiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_api_dispatch_group ("monitor", monitor_subcmds,
                                     transport, argc, argv, 2);
}
