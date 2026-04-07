/* cmacs-org-ex.c — org-ex Emacs DEFUN bridge
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Bridges liborgex GObject types to Emacs Lisp as DEFUNs.
 * All GObject return values are wrapped via cmacs_gobject_wrap().
 * Signal connections use gobject-connect from the GObject bridge.
 */

#include <config.h>

#ifdef HAVE_CMACS_ORG_EX

#include "lisp.h"
#include "cmacs-gobject.h"

#define ORG_EX_COMPILATION
#include "lib/org-ex.h"

/* ──────────────────────────────────────────────────────────────────── */
/* Document management                                                 */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("org-ex-document-create", Forg_ex_document_create,
       Sorg_ex_document_create, 0, 1, 0,
       doc: /* Create an org-ex document manager.
FILE-PATH is the path to the org file, or nil.
Returns a GObject (OrgExDocument).  */)
  (Lisp_Object file_path)
{
  OrgExDocument *doc;
  const char *path = NULL;

  if (!NILP (file_path))
    {
      CHECK_STRING (file_path);
      path = SSDATA (file_path);
    }

  doc = org_ex_document_new (path);
  return cmacs_gobject_wrap (G_OBJECT (doc));
}

DEFUN ("org-ex-document-register-widget",
       Forg_ex_document_register_widget,
       Sorg_ex_document_register_widget, 3, 3, 0,
       doc: /* Register WIDGET with DOCUMENT under ID.
DOCUMENT is an OrgExDocument, ID is a string, WIDGET is an OrgExWidget.  */)
  (Lisp_Object document, Lisp_Object id, Lisp_Object widget)
{
  GObject *doc_obj, *widget_obj;

  CHECK_STRING (id);

  doc_obj = cmacs_gobject_unwrap (document);
  widget_obj = cmacs_gobject_unwrap (widget);

  if (!ORG_EX_IS_DOCUMENT (doc_obj))
    error ("Expected OrgExDocument");
  if (!ORG_EX_IS_WIDGET (widget_obj))
    error ("Expected OrgExWidget");

  org_ex_document_register_widget (ORG_EX_DOCUMENT (doc_obj),
                                   SSDATA (id),
                                   ORG_EX_WIDGET (widget_obj));
  return Qnil;
}

DEFUN ("org-ex-document-get-widget", Forg_ex_document_get_widget,
       Sorg_ex_document_get_widget, 2, 2, 0,
       doc: /* Get widget by ID from DOCUMENT.
Returns the OrgExWidget, or nil if not found.  */)
  (Lisp_Object document, Lisp_Object id)
{
  GObject *doc_obj;
  OrgExWidget *widget;

  CHECK_STRING (id);
  doc_obj = cmacs_gobject_unwrap (document);
  if (!ORG_EX_IS_DOCUMENT (doc_obj))
    error ("Expected OrgExDocument");

  widget = org_ex_document_get_widget (ORG_EX_DOCUMENT (doc_obj),
                                       SSDATA (id));
  if (widget == NULL)
    return Qnil;

  return cmacs_gobject_wrap (G_OBJECT (widget));
}

DEFUN ("org-ex-document-remove-widget", Forg_ex_document_remove_widget,
       Sorg_ex_document_remove_widget, 2, 2, 0,
       doc: /* Remove and teardown widget ID from DOCUMENT.  */)
  (Lisp_Object document, Lisp_Object id)
{
  GObject *doc_obj;

  CHECK_STRING (id);
  doc_obj = cmacs_gobject_unwrap (document);
  if (!ORG_EX_IS_DOCUMENT (doc_obj))
    error ("Expected OrgExDocument");

  org_ex_document_remove_widget (ORG_EX_DOCUMENT (doc_obj),
                                 SSDATA (id));
  return Qnil;
}

DEFUN ("org-ex-document-teardown-all", Forg_ex_document_teardown_all,
       Sorg_ex_document_teardown_all, 1, 1, 0,
       doc: /* Teardown and remove all widgets from DOCUMENT.  */)
  (Lisp_Object document)
{
  GObject *doc_obj;

  doc_obj = cmacs_gobject_unwrap (document);
  if (!ORG_EX_IS_DOCUMENT (doc_obj))
    error ("Expected OrgExDocument");

  org_ex_document_teardown_all (ORG_EX_DOCUMENT (doc_obj));
  return Qnil;
}

DEFUN ("org-ex-document-notify-property-changed",
       Forg_ex_document_notify_property_changed,
       Sorg_ex_document_notify_property_changed, 3, 3, 0,
       doc: /* Notify DOCUMENT that org property NAME changed to VALUE.  */)
  (Lisp_Object document, Lisp_Object name, Lisp_Object value)
{
  GObject *doc_obj;

  CHECK_STRING (name);
  CHECK_STRING (value);
  doc_obj = cmacs_gobject_unwrap (document);
  if (!ORG_EX_IS_DOCUMENT (doc_obj))
    error ("Expected OrgExDocument");

  org_ex_document_notify_property_changed (ORG_EX_DOCUMENT (doc_obj),
                                            SSDATA (name),
                                            SSDATA (value));
  return Qnil;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Widget creation                                                     */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("org-ex-widget-gtk-new", Forg_ex_widget_gtk_new,
       Sorg_ex_widget_gtk_new, 1, 1, 0,
       doc: /* Create an OrgExWidgetGtk wrapping GTK-WIDGET.
GTK-WIDGET must be a GObject (GtkWidget).
Returns an OrgExWidgetGtk.  */)
  (Lisp_Object gtk_widget)
{
  GObject *gobj;
  OrgExWidgetGtk *widget;

  gobj = cmacs_gobject_unwrap (gtk_widget);
  widget = org_ex_widget_gtk_new (gobj);

  return cmacs_gobject_wrap (G_OBJECT (widget));
}

DEFUN ("org-ex-widget-web-new", Forg_ex_widget_web_new,
       Sorg_ex_widget_web_new, 3, 3, 0,
       doc: /* Create an OrgExWidgetWeb for URL with WIDTH x HEIGHT.  */)
  (Lisp_Object url, Lisp_Object width, Lisp_Object height)
{
  OrgExWidgetWeb *widget;
  const char *url_str = NULL;

  if (!NILP (url))
    {
      CHECK_STRING (url);
      url_str = SSDATA (url);
    }
  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);

  widget = org_ex_widget_web_new (url_str,
                                  (gint)XFIXNUM (width),
                                  (gint)XFIXNUM (height));
  return cmacs_gobject_wrap (G_OBJECT (widget));
}

DEFUN ("org-ex-widget-web-new-from-html",
       Forg_ex_widget_web_new_from_html,
       Sorg_ex_widget_web_new_from_html, 3, 3, 0,
       doc: /* Create an OrgExWidgetWeb from inline HTML with WIDTH x HEIGHT.  */)
  (Lisp_Object html, Lisp_Object width, Lisp_Object height)
{
  OrgExWidgetWeb *widget;

  CHECK_STRING (html);
  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);

  widget = org_ex_widget_web_new_from_html (SSDATA (html),
                                             (gint)XFIXNUM (width),
                                             (gint)XFIXNUM (height));
  return cmacs_gobject_wrap (G_OBJECT (widget));
}

DEFUN ("org-ex-widget-buffer-new", Forg_ex_widget_buffer_new,
       Sorg_ex_widget_buffer_new, 1, 2, 0,
       doc: /* Create an OrgExWidgetBuffer for FILE.
EDITABLE defaults to nil (view-only).  */)
  (Lisp_Object file, Lisp_Object editable)
{
  OrgExWidgetBuffer *widget;

  CHECK_STRING (file);

  widget = org_ex_widget_buffer_new (SSDATA (file),
                                      !NILP (editable));
  return cmacs_gobject_wrap (G_OBJECT (widget));
}

DEFUN ("org-ex-widget-code-new", Forg_ex_widget_code_new,
       Sorg_ex_widget_code_new, 2, 2, 0,
       doc: /* Create an OrgExWidgetCode for LANGUAGE with CODE.
LANGUAGE is "elisp", "crispy", or "bacon".  */)
  (Lisp_Object language, Lisp_Object code)
{
  OrgExWidgetCode *widget;

  CHECK_STRING (language);
  CHECK_STRING (code);

  widget = org_ex_widget_code_new (SSDATA (language),
                                    SSDATA (code));
  return cmacs_gobject_wrap (G_OBJECT (widget));
}

/* ──────────────────────────────────────────────────────────────────── */
/* Widget operations                                                   */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("org-ex-widget-set-size", Forg_ex_widget_set_size,
       Sorg_ex_widget_set_size, 3, 3, 0,
       doc: /* Set WIDGET dimensions to WIDTH x HEIGHT.  */)
  (Lisp_Object widget, Lisp_Object width, Lisp_Object height)
{
  GObject *gobj;

  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);

  gobj = cmacs_gobject_unwrap (widget);
  if (!ORG_EX_IS_WIDGET (gobj))
    error ("Expected OrgExWidget");

  org_ex_widget_set_size (ORG_EX_WIDGET (gobj),
                           (gint)XFIXNUM (width),
                           (gint)XFIXNUM (height));
  return Qnil;
}

DEFUN ("org-ex-widget-teardown", Forg_ex_widget_teardown,
       Sorg_ex_widget_teardown, 1, 1, 0,
       doc: /* Teardown WIDGET, releasing display resources.  */)
  (Lisp_Object widget)
{
  GObject *gobj;

  gobj = cmacs_gobject_unwrap (widget);
  if (!ORG_EX_IS_WIDGET (gobj))
    error ("Expected OrgExWidget");

  org_ex_widget_teardown (ORG_EX_WIDGET (gobj));
  return Qnil;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Binding and channels                                                */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("org-ex-binding-create", Forg_ex_binding_create,
       Sorg_ex_binding_create, 3, 4, 0,
       doc: /* Create a reactive binding between PROPERTY and WIDGET in DOCUMENT.
DIRECTION is a symbol: `bidirectional' (default), `to-widget', or `from-widget'.
Returns an OrgExBinding.  */)
  (Lisp_Object document, Lisp_Object property_name,
   Lisp_Object widget, Lisp_Object direction)
{
  GObject *doc_obj, *widget_obj;
  OrgExBindingDirection dir = ORG_EX_BINDING_BIDIRECTIONAL;
  OrgExBinding *binding;

  CHECK_STRING (property_name);

  doc_obj = cmacs_gobject_unwrap (document);
  widget_obj = cmacs_gobject_unwrap (widget);

  if (!ORG_EX_IS_DOCUMENT (doc_obj))
    error ("Expected OrgExDocument");
  if (!ORG_EX_IS_WIDGET (widget_obj))
    error ("Expected OrgExWidget");

  if (!NILP (direction))
    {
      CHECK_SYMBOL (direction);
      if (EQ (direction, intern_c_string ("to-widget")))
        dir = ORG_EX_BINDING_TO_WIDGET;
      else if (EQ (direction, intern_c_string ("from-widget")))
        dir = ORG_EX_BINDING_FROM_WIDGET;
    }

  binding = org_ex_binding_new (ORG_EX_DOCUMENT (doc_obj),
                                SSDATA (property_name),
                                ORG_EX_WIDGET (widget_obj),
                                dir);
  return cmacs_gobject_wrap (G_OBJECT (binding));
}

DEFUN ("org-ex-channel-create", Forg_ex_channel_create,
       Sorg_ex_channel_create, 1, 1, 0,
       doc: /* Create a named pub/sub channel.
Returns an OrgExChannel.  */)
  (Lisp_Object name)
{
  OrgExChannel *channel;

  CHECK_STRING (name);
  channel = org_ex_channel_new (SSDATA (name));

  return cmacs_gobject_wrap (G_OBJECT (channel));
}

DEFUN ("org-ex-channel-publish", Forg_ex_channel_publish,
       Sorg_ex_channel_publish, 2, 2, 0,
       doc: /* Publish VALUE on CHANNEL.
All subscribers' ::message signal handlers will fire.  */)
  (Lisp_Object channel, Lisp_Object value)
{
  GObject *gobj;

  CHECK_STRING (value);
  gobj = cmacs_gobject_unwrap (channel);
  if (!ORG_EX_IS_CHANNEL (gobj))
    error ("Expected OrgExChannel");

  org_ex_channel_publish (ORG_EX_CHANNEL (gobj), SSDATA (value));
  return Qnil;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Export                                                               */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("org-ex-widget-export-html", Forg_ex_widget_export_html,
       Sorg_ex_widget_export_html, 1, 1, 0,
       doc: /* Export WIDGET as an HTML string.
Returns nil if widget does not implement OrgExExportable.  */)
  (Lisp_Object widget)
{
  GObject *gobj;
  gchar *html;
  Lisp_Object result;

  gobj = cmacs_gobject_unwrap (widget);
  if (!ORG_EX_IS_EXPORTABLE (gobj))
    return Qnil;

  html = org_ex_exportable_export_html (ORG_EX_EXPORTABLE (gobj), NULL);
  if (html == NULL)
    return Qnil;

  result = build_string (html);
  g_free (html);
  return result;
}

DEFUN ("org-ex-widget-export-text", Forg_ex_widget_export_text,
       Sorg_ex_widget_export_text, 1, 1, 0,
       doc: /* Export WIDGET as a plain text description.
Returns nil if widget does not implement OrgExExportable.  */)
  (Lisp_Object widget)
{
  GObject *gobj;
  gchar *text;
  Lisp_Object result;

  gobj = cmacs_gobject_unwrap (widget);
  if (!ORG_EX_IS_EXPORTABLE (gobj))
    return Qnil;

  text = org_ex_exportable_export_text (ORG_EX_EXPORTABLE (gobj), NULL);
  if (text == NULL)
    return Qnil;

  result = build_string (text);
  g_free (text);
  return result;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Code widget helpers                                                 */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("org-ex-widget-code-set-result",
       Forg_ex_widget_code_set_result,
       Sorg_ex_widget_code_set_result, 2, 2, 0,
       doc: /* Set the RESULT widget on CODE-WIDGET after evaluation.  */)
  (Lisp_Object code_widget, Lisp_Object result)
{
  GObject *code_obj, *result_obj;

  code_obj = cmacs_gobject_unwrap (code_widget);
  if (!ORG_EX_IS_WIDGET_CODE (code_obj))
    error ("Expected OrgExWidgetCode");

  if (NILP (result))
    {
      org_ex_widget_code_set_result (ORG_EX_WIDGET_CODE (code_obj),
                                      NULL);
    }
  else
    {
      result_obj = cmacs_gobject_unwrap (result);
      if (!ORG_EX_IS_WIDGET (result_obj))
        error ("Expected OrgExWidget as result");
      org_ex_widget_code_set_result (ORG_EX_WIDGET_CODE (code_obj),
                                      ORG_EX_WIDGET (result_obj));
    }

  return Qnil;
}

DEFUN ("org-ex-widget-gtk-get-widget", Forg_ex_widget_gtk_get_widget,
       Sorg_ex_widget_gtk_get_widget, 1, 1, 0,
       doc: /* Get the underlying GtkWidget from an OrgExWidgetGtk.
WIDGET must be an OrgExWidgetGtk GObject.
Returns the wrapped GtkWidget as a GObject, or nil.  */)
  (Lisp_Object widget)
{
  GObject *gobj = cmacs_gobject_unwrap (widget);

  if (!ORG_EX_IS_WIDGET_GTK (gobj))
    error ("Expected OrgExWidgetGtk");

  gpointer gtk_widget = org_ex_widget_gtk_get_gtk_widget (
    ORG_EX_WIDGET_GTK (gobj));

  if (gtk_widget == NULL)
    return Qnil;

  return cmacs_gobject_wrap (G_OBJECT (gtk_widget));
}

/* ──────────────────────────────────────────────────────────────────── */
/* Symbol registration                                                 */
/* ──────────────────────────────────────────────────────────────────── */

void
syms_of_cmacs_org_ex (void)
{
  defsubr (&Sorg_ex_document_create);
  defsubr (&Sorg_ex_document_register_widget);
  defsubr (&Sorg_ex_document_get_widget);
  defsubr (&Sorg_ex_document_remove_widget);
  defsubr (&Sorg_ex_document_teardown_all);
  defsubr (&Sorg_ex_document_notify_property_changed);

  defsubr (&Sorg_ex_widget_gtk_new);
  defsubr (&Sorg_ex_widget_web_new);
  defsubr (&Sorg_ex_widget_web_new_from_html);
  defsubr (&Sorg_ex_widget_buffer_new);
  defsubr (&Sorg_ex_widget_code_new);

  defsubr (&Sorg_ex_widget_set_size);
  defsubr (&Sorg_ex_widget_teardown);

  defsubr (&Sorg_ex_binding_create);
  defsubr (&Sorg_ex_channel_create);
  defsubr (&Sorg_ex_channel_publish);

  defsubr (&Sorg_ex_widget_export_html);
  defsubr (&Sorg_ex_widget_export_text);

  defsubr (&Sorg_ex_widget_code_set_result);

  defsubr (&Sorg_ex_widget_gtk_get_widget);
}

#endif /* HAVE_CMACS_ORG_EX */
