/* cmacs-gsurf-print.c --- print a gsurf page to PDF.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * gsurf has no print support, so cmacs drives WebKitPrintOperation
 * directly on the native widget: a GtkPrintSettings configured for the
 * "print to file" PDF backend (OUTPUT_URI + OUTPUT_FILE_FORMAT) prints
 * without a dialog.  webkit_print_operation_print returns quickly; the
 * actual render completes asynchronously on the "finished"/"failed"
 * signals, which deliver the result to an optional one-shot Lisp callback
 * via the cookie registry. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "cmacs-gsurf.h"
#include "cmacs-eval-dispatch.h"

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

typedef struct
{
  WebKitPrintOperation *op;       /* owned ref from _new */
  uint64_t              cb_cookie;/* 0 = no callback */
  char                 *path;     /* owned destination path */
} CmacsGsurfPrint;

/* Both terminal signals route here.  The emission holds a ref on OP, so
   unreffing it inside the handler is safe. */
static void
print_done (CmacsGsurfPrint *c, Lisp_Object result)
{
  if (c->cb_cookie)
    cmacs_dispatch_callback_invoke1 (c->cb_cookie, result);
  g_object_unref (c->op);
  g_free (c->path);
  g_free (c);
}

static void
on_print_finished (WebKitPrintOperation *op, gpointer user)
{
  CmacsGsurfPrint *c = user;
  (void) op;
  print_done (c, build_string (c->path));
}

static void
on_print_failed (WebKitPrintOperation *op, GError *error, gpointer user)
{
  CmacsGsurfPrint *c = user;
  (void) op; (void) error;
  print_done (c, Qnil);
}

void
cmacs_gsurf_print_pdf (CmacsGsurfView *v, const char *path,
                       Lisp_Object callback)
{
  void *w = cmacs_gsurf_view_native_widget (v);
  if (w == NULL || path == NULL)
    return;

  WebKitPrintOperation *op = webkit_print_operation_new (WEBKIT_WEB_VIEW (w));
  GtkPrintSettings *settings = gtk_print_settings_new ();
  g_autofree char *uri = g_filename_to_uri (path, NULL, NULL);
  if (uri != NULL)
    gtk_print_settings_set (settings, GTK_PRINT_SETTINGS_OUTPUT_URI, uri);
  gtk_print_settings_set (settings, GTK_PRINT_SETTINGS_OUTPUT_FILE_FORMAT,
                          "pdf");
  webkit_print_operation_set_print_settings (op, settings);
  g_object_unref (settings);

  CmacsGsurfPrint *c = g_new0 (CmacsGsurfPrint, 1);
  c->op        = op;
  c->path      = g_strdup (path);
  c->cb_cookie = NILP (callback) ? 0
    : cmacs_dispatch_callback_register (callback);
  g_signal_connect (op, "finished", G_CALLBACK (on_print_finished), c);
  g_signal_connect (op, "failed",   G_CALLBACK (on_print_failed),   c);

  webkit_print_operation_print (op);
}

#endif /* HAVE_CMACS_GSURF */
