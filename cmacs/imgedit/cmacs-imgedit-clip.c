/* cmacs-imgedit-clip.c --- in-process GTK image clipboard (pgtk).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-imgedit-clip.h.  This TU includes <gtk/gtk.h> and must never
 * include lisp.h (the DEFUN layer calls through the plain-C API).  */

#include <config.h>

#ifdef HAVE_CMACS_IMGEDIT

#include "cmacs-imgedit-clip.h"

#ifdef HAVE_PGTK

#include <gtk/gtk.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

gboolean
cmacs_imgedit_clip_available (void)
{
  return gdk_display_get_default () != NULL;
}

gboolean
cmacs_imgedit_clip_set_png (const guint8 *png, gsize n, char **error_msg)
{
  GdkPixbufLoader *loader;
  GdkPixbuf *pixbuf;
  GtkClipboard *clip;
  GError *err = NULL;

  if (error_msg)
    *error_msg = NULL;
  if (!cmacs_imgedit_clip_available ())
    {
      if (error_msg)
        *error_msg = g_strdup ("no GTK display connection");
      return FALSE;
    }
  if (png == NULL || n == 0)
    {
      if (error_msg)
        *error_msg = g_strdup ("empty image");
      return FALSE;
    }

  loader = gdk_pixbuf_loader_new ();
  if (!gdk_pixbuf_loader_write (loader, png, n, &err)
      || !gdk_pixbuf_loader_close (loader, &err))
    {
      if (error_msg)
        *error_msg = g_strdup (err ? err->message : "could not decode PNG");
      g_clear_error (&err);
      g_object_unref (loader);
      return FALSE;
    }
  pixbuf = gdk_pixbuf_loader_get_pixbuf (loader); /* owned by loader */
  if (pixbuf == NULL)
    {
      if (error_msg)
        *error_msg = g_strdup ("could not decode PNG");
      g_object_unref (loader);
      return FALSE;
    }

  clip = gtk_clipboard_get (GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_image (clip, pixbuf);
  g_object_unref (loader);
  return TRUE;
}

guint8 *
cmacs_imgedit_clip_get_png (gsize *out_n, char **error_msg)
{
  GtkClipboard *clip;
  GdkPixbuf *pixbuf;
  gchar *buf = NULL;
  gsize n = 0;
  GError *err = NULL;

  if (out_n)
    *out_n = 0;
  if (error_msg)
    *error_msg = NULL;
  if (!cmacs_imgedit_clip_available ())
    return NULL;

  clip = gtk_clipboard_get (GDK_SELECTION_CLIPBOARD);
  /* Runs a short nested loop while the owner transfers the image; called
     from a user command (never from input-wait), so this is safe.  */
  pixbuf = gtk_clipboard_wait_for_image (clip);
  if (pixbuf == NULL)
    return NULL;                /* no image on the clipboard */

  if (!gdk_pixbuf_save_to_buffer (pixbuf, &buf, &n, "png", &err, NULL))
    {
      if (error_msg)
        *error_msg = g_strdup (err ? err->message : "PNG encode failed");
      g_clear_error (&err);
      g_object_unref (pixbuf);
      return NULL;
    }
  g_object_unref (pixbuf);
  if (out_n)
    *out_n = n;
  return (guint8 *) buf;        /* g_free-able */
}

#else /* !HAVE_PGTK */

gboolean
cmacs_imgedit_clip_available (void)
{
  return FALSE;
}

gboolean
cmacs_imgedit_clip_set_png (const guint8 *png, gsize n, char **error_msg)
{
  (void) png;
  (void) n;
  if (error_msg)
    *error_msg = g_strdup ("built without pgtk");
  return FALSE;
}

guint8 *
cmacs_imgedit_clip_get_png (gsize *out_n, char **error_msg)
{
  if (out_n)
    *out_n = 0;
  if (error_msg)
    *error_msg = NULL;
  return NULL;
}

#endif /* HAVE_PGTK */

#endif /* HAVE_CMACS_IMGEDIT */
