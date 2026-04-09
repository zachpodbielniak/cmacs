/* org-ex-widget-gtk.c — GTK widget wrapper implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-widget-gtk.h"
#include "../interfaces/org-ex-exportable.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-widget-gtk
 * @title: OrgExWidgetGtk
 * @short_description: Wraps a GtkWidget for embedding in org documents
 *
 * #OrgExWidgetGtk wraps any GtkWidget created via the GI bridge or
 * directly from C.  The widget is rendered via the Gowl Wayland
 * compositor (under Wayland) or the xwidget offscreen rendering path.
 *
 * The underlying GtkWidget pointer is stored as a gpointer to avoid
 * a hard dependency on GTK headers in liborgex.
 */

struct _OrgExWidgetGtk
{
  OrgExWidget parent_instance;
  gpointer    gtk_widget;    /* GtkWidget*, no GTK dep in library */
};

/* ---- OrgExExportable interface ---- */

static gchar *
org_ex_widget_gtk_export_html (OrgExExportable *exportable,
                               GError         **error)
{
  (void) error;
  (void) exportable;
  /* Generic fallback; Elisp side overrides per widget subtype */
  return g_strdup ("<div class=\"org-ex-widget\">"
                   "[GTK Widget]</div>");
}

static gchar *
org_ex_widget_gtk_export_text (OrgExExportable *exportable,
                               GError         **error)
{
  (void) error;
  (void) exportable;
  return g_strdup ("[Widget: gtk]");
}

static void
org_ex_widget_gtk_exportable_init (OrgExExportableInterface *iface)
{
  iface->export_html = org_ex_widget_gtk_export_html;
  iface->export_text = org_ex_widget_gtk_export_text;
}

G_DEFINE_FINAL_TYPE_WITH_CODE (
  OrgExWidgetGtk, org_ex_widget_gtk, ORG_EX_TYPE_WIDGET,
  G_IMPLEMENT_INTERFACE (ORG_EX_TYPE_EXPORTABLE,
                         org_ex_widget_gtk_exportable_init))

/* ---- OrgExWidget vfunc overrides ---- */

static gpointer
org_ex_widget_gtk_render (OrgExWidget *widget,
                          gpointer     display_context,
                          GError     **error)
{
  OrgExWidgetGtk *self = ORG_EX_WIDGET_GTK (widget);

  if (self->gtk_widget == NULL)
    {
      g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_RENDER,
                           "GTK widget is NULL");
      return NULL;
    }

  /* The actual rendering is handled by Elisp via gowl-make-xwidget
     or the xwidget offscreen path.  This returns the GtkWidget pointer
     so the DEFUN bridge can pass it to the display system. */
  return self->gtk_widget;
}

static void
org_ex_widget_gtk_teardown (OrgExWidget *widget)
{
  OrgExWidgetGtk *self = ORG_EX_WIDGET_GTK (widget);

  if (self->gtk_widget != NULL)
    {
      g_object_unref (self->gtk_widget);
      self->gtk_widget = NULL;
    }
}

/* ---- GObject lifecycle ---- */

static void
org_ex_widget_gtk_dispose (GObject *object)
{
  OrgExWidgetGtk *self = ORG_EX_WIDGET_GTK (object);

  g_clear_object (&self->gtk_widget);

  G_OBJECT_CLASS (org_ex_widget_gtk_parent_class)->dispose (object);
}

static void
org_ex_widget_gtk_class_init (OrgExWidgetGtkClass *klass)
{
  GObjectClass     *object_class = G_OBJECT_CLASS (klass);
  OrgExWidgetClass *widget_class = ORG_EX_WIDGET_CLASS (klass);

  object_class->dispose = org_ex_widget_gtk_dispose;

  widget_class->render = org_ex_widget_gtk_render;
  widget_class->teardown = org_ex_widget_gtk_teardown;
}

static void
org_ex_widget_gtk_init (OrgExWidgetGtk *self)
{
  self->gtk_widget = NULL;
}

/* ---- Public API ---- */

OrgExWidgetGtk *
org_ex_widget_gtk_new (gpointer gtk_widget)
{
  OrgExWidgetGtk *self;

  g_return_val_if_fail (G_IS_OBJECT (gtk_widget), NULL);

  self = g_object_new (ORG_EX_TYPE_WIDGET_GTK,
                       "widget-type", ORG_EX_WIDGET_TYPE_GTK,
                       NULL);
  self->gtk_widget = g_object_ref_sink (gtk_widget);

  return self;
}

gpointer
org_ex_widget_gtk_get_gtk_widget (OrgExWidgetGtk *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_GTK (self), NULL);

  return self->gtk_widget;
}
