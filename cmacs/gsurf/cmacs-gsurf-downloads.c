/* cmacs-gsurf-downloads.c --- download tracking for the gsurf browser.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * gsurf (deps/gsurf) only dispatches a download's *destination* to a
 * module; it tracks no progress and emits no host signal.  cmacs owns the
 * full download lifecycle here by listening directly on the process-global
 * default WebKitWebContext (cmacs already links webkit2gtk-4.1).  Downloads
 * auto-save (eww-style, non-blocking) into `cmacs-gsurf-download-directory'
 * and their lifecycle is delivered to Emacs through the abnormal hook
 * `cmacs-gsurf-download-changed-functions', which the *gsurf-downloads*
 * buffer (lisp/cmacs/cmacs-gsurf-downloads.el) renders.
 *
 * Lifetime: the default WebContext is process-global and WebKitDownloads
 * outlive the view that started them, so this module keeps a pure-C
 * id->download map (no Lisp_Object, no GC interaction) and never captures a
 * CmacsGsurfView.  All signal handlers run on the Emacs main thread inside
 * cmacs_glib_dispatch, so calling the safe-dispatch layer is fine; the
 * frequent `received-data' signal is throttled to whole-percent changes. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "cmacs-gsurf.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>
#include <webkit2/webkit2.h>

/* ── State ──────────────────────────────────────────────────────────── */

typedef struct
{
  guint           id;
  WebKitDownload *download;     /* reffed; unreffed in forget_download */
  char           *uri;         /* request URI (g_strdup) */
  char           *dest;        /* local destination path, or NULL */
  int             last_percent;/* last emitted whole percent, -1 = none */
} CmacsGsurfDownload;

static GHashTable *downloads        = NULL;  /* id -> CmacsGsurfDownload* */
static guint       next_download_id = 1;
static gboolean    downloads_wired  = FALSE;

/* ── Helpers ────────────────────────────────────────────────────────── */

/* Resolve the Emacs-side download directory (read the defcustom value,
   expand a leading ~/).  Reading a Lisp variable is a pure cell read (no
   eval / no signal), so it is safe from a GTK signal handler.  Caller
   g_free's. */
static char *
download_dir (void)
{
  Lisp_Object v = find_symbol_value (intern ("cmacs-gsurf-download-directory"));
  const char *dir = STRINGP (v) ? SSDATA (v) : NULL;
  if (dir == NULL || *dir == '\0')
    return g_build_filename (g_get_home_dir (), "Downloads", NULL);
  if (dir[0] == '~' && (dir[1] == '/' || dir[1] == '\0'))
    return g_build_filename (g_get_home_dir (), dir + 1, NULL);
  return g_strdup (dir);
}

/* If PATH already exists, return a de-duplicated sibling ("name (1).ext",
   ...).  Always returns a freshly g_malloc'd path. */
static char *
dedup_path (const char *path)
{
  if (!g_file_test (path, G_FILE_TEST_EXISTS))
    return g_strdup (path);

  g_autofree char *dir  = g_path_get_dirname (path);
  g_autofree char *base = g_path_get_basename (path);
  const char *dot = strrchr (base, '.');
  g_autofree char *stem =
    dot ? g_strndup (base, (gsize) (dot - base)) : g_strdup (base);
  const char *ext = dot ? dot : "";

  for (int n = 1; n < 10000; n++)
    {
      g_autofree char *name = g_strdup_printf ("%s (%d)%s", stem, n, ext);
      char *cand = g_build_filename (dir, name, NULL);
      if (!g_file_test (cand, G_FILE_TEST_EXISTS))
        return cand;
      g_free (cand);
    }
  return g_strdup (path);
}

/* Fire (run-hook-with-args 'cmacs-gsurf-download-changed-functions
   ID URI DEST RECEIVED TOTAL STATE) on the Emacs main thread. */
static void
emit_download_event (CmacsGsurfDownload *d, const char *state)
{
  guint64 received =
    webkit_download_get_received_data_length (d->download);
  WebKitURIResponse *resp = webkit_download_get_response (d->download);
  guint64 total =
    resp ? webkit_uri_response_get_content_length (resp) : 0;

  Lisp_Object args[7];
  args[0] = intern ("cmacs-gsurf-download-changed-functions");
  args[1] = make_uint (d->id);
  args[2] = build_string (d->uri  ? d->uri  : "");
  args[3] = build_string (d->dest ? d->dest : "");
  args[4] = make_uint (received);
  args[5] = make_uint (total);
  args[6] = intern (state);
  cmacs_dispatch_safe_callN (intern ("run-hook-with-args"), 7, args);
}

static void
forget_download (CmacsGsurfDownload *d)
{
  if (!d)
    return;
  guint id = d->id;
  if (d->download)
    {
      g_signal_handlers_disconnect_by_data (d->download, d);
      g_object_unref (d->download);
      d->download = NULL;
    }
  /* The table's value-destroy (download_free) frees URI/DEST and D. */
  if (downloads)
    g_hash_table_remove (downloads, GUINT_TO_POINTER (id));
}

static void
download_free (gpointer p)
{
  CmacsGsurfDownload *d = p;
  if (!d)
    return;
  g_free (d->uri);
  g_free (d->dest);
  g_free (d);
}

/* ── Per-download signal handlers ───────────────────────────────────── */

static gboolean
on_decide_destination (WebKitDownload *download, const gchar *suggested,
                       gpointer user)
{
  CmacsGsurfDownload *d = user;
  g_autofree char *dir = download_dir ();
  g_mkdir_with_parents (dir, 0700);

  const char *name = (suggested && *suggested) ? suggested : "download";
  g_autofree char *safe = g_path_get_basename (name);  /* strip any path */
  g_autofree char *want = g_build_filename (dir, safe, NULL);
  char *path = dedup_path (want);

  g_autofree char *file_uri = g_filename_to_uri (path, NULL, NULL);
  if (file_uri != NULL)
    webkit_download_set_destination (download, file_uri);

  g_free (d->dest);
  d->dest = path;                 /* transfer ownership */
  emit_download_event (d, "progress");
  return TRUE;
}

static void
on_received_data (WebKitDownload *download, guint64 length, gpointer user)
{
  CmacsGsurfDownload *d = user;
  (void) length;
  int pct = (int) (webkit_download_get_estimated_progress (download) * 100.0);
  if (pct != d->last_percent)
    {
      d->last_percent = pct;
      emit_download_event (d, "progress");
    }
}

static void
on_finished (WebKitDownload *download, gpointer user)
{
  CmacsGsurfDownload *d = user;
  (void) download;
  emit_download_event (d, "finished");
  forget_download (d);
}

static void
on_failed (WebKitDownload *download, GError *error, gpointer user)
{
  CmacsGsurfDownload *d = user;
  (void) download;
  const char *state =
    (error && g_error_matches (error, WEBKIT_DOWNLOAD_ERROR,
                               WEBKIT_DOWNLOAD_ERROR_CANCELLED_BY_USER))
    ? "cancelled" : "failed";
  emit_download_event (d, state);
  forget_download (d);
}

static void
on_download_started (WebKitWebContext *context, WebKitDownload *download,
                     gpointer user)
{
  (void) context; (void) user;
  CmacsGsurfDownload *d = g_new0 (CmacsGsurfDownload, 1);
  d->id           = next_download_id++;
  d->download     = g_object_ref (download);
  d->last_percent = -1;

  WebKitURIRequest *req = webkit_download_get_request (download);
  const gchar *uri = req ? webkit_uri_request_get_uri (req) : NULL;
  d->uri = g_strdup (uri ? uri : "");

  g_hash_table_insert (downloads, GUINT_TO_POINTER (d->id), d);

  g_signal_connect (download, "decide-destination",
                    G_CALLBACK (on_decide_destination), d);
  g_signal_connect (download, "received-data",
                    G_CALLBACK (on_received_data), d);
  g_signal_connect (download, "finished",
                    G_CALLBACK (on_finished), d);
  g_signal_connect (download, "failed",
                    G_CALLBACK (on_failed), d);

  emit_download_event (d, "started");
}

/* ── Public API (cmacs-gsurf.h) ─────────────────────────────────────── */

void
cmacs_gsurf_downloads_init (void)
{
  if (downloads_wired)
    return;
  downloads_wired = TRUE;
  downloads = g_hash_table_new_full (g_direct_hash, g_direct_equal,
                                     NULL, download_free);
  /* The default WebContext is shared by every WebKitWebView the embed
     creates, so connecting once here covers all gsurf buffers. */
  WebKitWebContext *ctx = webkit_web_context_get_default ();
  g_signal_connect (ctx, "download-started",
                    G_CALLBACK (on_download_started), NULL);
}

void
cmacs_gsurf_download_cancel (unsigned int id)
{
  if (!downloads)
    return;
  CmacsGsurfDownload *d =
    g_hash_table_lookup (downloads, GUINT_TO_POINTER (id));
  if (d && d->download)
    webkit_download_cancel (d->download);  /* -> on_failed -> forget */
}

#endif /* HAVE_CMACS_GSURF */
