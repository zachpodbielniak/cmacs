/* cmacs-gsurf-snapshot.c --- page snapshots for the gsurf browser.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Renders a gsurf view to a PNG file.  We call webkit_web_view_get_snapshot
 * directly on the native widget (rather than gsurf's wrapper, which is fixed
 * to the visible region) so the caller can request the full document.  The
 * result is delivered to an optional one-shot Lisp callback via the
 * staticpro'd cookie registry, hopping onto the cmacs main context first
 * (the whisper/JS pattern; never hold a raw Lisp_Object across the gap). */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "cmacs-gsurf.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"

#include <cairo.h>
#include <webkit2/webkit2.h>

typedef struct
{
  WebKitWebView *view;     /* reffed */
  uint64_t       cb_cookie;/* 0 = no callback */
  char          *path;     /* owned destination path */
  gboolean       ok;
} CmacsGsurfSnap;

static gboolean
snap_main (gpointer data)
{
  CmacsGsurfSnap *c = data;
  if (c->cb_cookie)
    cmacs_dispatch_callback_invoke1 (c->cb_cookie,
                                     c->ok ? build_string (c->path) : Qnil);
  g_free (c->path);
  g_object_unref (c->view);
  g_free (c);
  return G_SOURCE_REMOVE;
}

static void
snap_finish (GObject *source, GAsyncResult *res, gpointer user)
{
  CmacsGsurfSnap *c = user;
  GError *err = NULL;
  (void) source;
  cairo_surface_t *surf =
    webkit_web_view_get_snapshot_finish (c->view, res, &err);
  if (surf != NULL)
    {
      c->ok = (cairo_surface_write_to_png (surf, c->path)
               == CAIRO_STATUS_SUCCESS);
      cairo_surface_destroy (surf);
    }
  g_clear_error (&err);
  g_main_context_invoke (cmacs_glib_get_context (), snap_main, c);
}

void
cmacs_gsurf_snapshot (CmacsGsurfView *v, const char *path,
                      Lisp_Object callback, bool full_page)
{
  void *w = cmacs_gsurf_view_native_widget (v);
  if (w == NULL || path == NULL)
    return;
  CmacsGsurfSnap *c = g_new0 (CmacsGsurfSnap, 1);
  c->view      = g_object_ref (WEBKIT_WEB_VIEW (w));
  c->path      = g_strdup (path);
  c->cb_cookie = NILP (callback) ? 0
    : cmacs_dispatch_callback_register (callback);
  webkit_web_view_get_snapshot (
    WEBKIT_WEB_VIEW (w),
    full_page ? WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT
              : WEBKIT_SNAPSHOT_REGION_VISIBLE,
    WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL, snap_finish, c);
}

#endif /* HAVE_CMACS_GSURF */
