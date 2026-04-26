/* org-ex-types.h — Forward declarations, error domain, and enums
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_TYPES_H
#define ORG_EX_TYPES_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib.h>
#include <glib-object.h>

G_BEGIN_DECLS

/* ---- Interface forward declarations ---- */

typedef struct _OrgExRenderable          OrgExRenderable;
typedef struct _OrgExRenderableInterface OrgExRenderableInterface;

typedef struct _OrgExExportable          OrgExExportable;
typedef struct _OrgExExportableInterface OrgExExportableInterface;

/* ---- Derivable type forward declarations ---- */

typedef struct _OrgExWidget      OrgExWidget;
typedef struct _OrgExWidgetClass OrgExWidgetClass;

/* ---- Final type forward declarations ---- */

typedef struct _OrgExWidgetGtk    OrgExWidgetGtk;
typedef struct _OrgExWidgetWeb    OrgExWidgetWeb;
typedef struct _OrgExWidgetBuffer OrgExWidgetBuffer;
typedef struct _OrgExWidgetCode   OrgExWidgetCode;
typedef struct _OrgExWidgetInk    OrgExWidgetInk;
typedef struct _OrgExDocument     OrgExDocument;
typedef struct _OrgExBinding      OrgExBinding;
typedef struct _OrgExChannel      OrgExChannel;

/* ---- Boxed type forward declarations ---- */

typedef struct _OrgExWidgetState OrgExWidgetState;

/* ---- Error domain ---- */

/**
 * ORG_EX_ERROR:
 *
 * Error domain for org-ex operations.
 */
#define ORG_EX_ERROR (org_ex_error_quark ())
GQuark org_ex_error_quark (void);

/**
 * OrgExError:
 * @ORG_EX_ERROR_INVALID_TYPE: Unknown or unsupported widget type
 * @ORG_EX_ERROR_RENDER: Widget rendering failed
 * @ORG_EX_ERROR_EVAL: Code evaluation failed
 * @ORG_EX_ERROR_BINDING: Property binding error
 * @ORG_EX_ERROR_STATE: State save/restore error
 * @ORG_EX_ERROR_EXPORT: Export failed
 *
 * Error codes for org-ex operations.
 */
typedef enum
{
  ORG_EX_ERROR_INVALID_TYPE,
  ORG_EX_ERROR_RENDER,
  ORG_EX_ERROR_EVAL,
  ORG_EX_ERROR_BINDING,
  ORG_EX_ERROR_STATE,
  ORG_EX_ERROR_EXPORT
} OrgExError;

/**
 * OrgExWidgetType:
 * @ORG_EX_WIDGET_TYPE_GTK: Native GTK widget
 * @ORG_EX_WIDGET_TYPE_WEB: WebKit web content
 * @ORG_EX_WIDGET_TYPE_BUFFER: Embedded Emacs buffer
 * @ORG_EX_WIDGET_TYPE_CODE: Evaluated code block output
 *
 * Enumeration of built-in widget types.
 */
typedef enum
{
  ORG_EX_WIDGET_TYPE_GTK,
  ORG_EX_WIDGET_TYPE_WEB,
  ORG_EX_WIDGET_TYPE_BUFFER,
  ORG_EX_WIDGET_TYPE_CODE,
  ORG_EX_WIDGET_TYPE_INK
} OrgExWidgetType;

#define ORG_EX_TYPE_WIDGET_TYPE (org_ex_widget_type_get_type ())
GType org_ex_widget_type_get_type (void) G_GNUC_CONST;

/**
 * OrgExBindingDirection:
 * @ORG_EX_BINDING_BIDIRECTIONAL: Widget and property update each other
 * @ORG_EX_BINDING_TO_WIDGET: Property changes update widget only
 * @ORG_EX_BINDING_FROM_WIDGET: Widget changes update property only
 *
 * Direction of a property binding.
 */
typedef enum
{
  ORG_EX_BINDING_BIDIRECTIONAL,
  ORG_EX_BINDING_TO_WIDGET,
  ORG_EX_BINDING_FROM_WIDGET
} OrgExBindingDirection;

#define ORG_EX_TYPE_BINDING_DIRECTION (org_ex_binding_direction_get_type ())
GType org_ex_binding_direction_get_type (void) G_GNUC_CONST;

G_END_DECLS

#endif /* ORG_EX_TYPES_H */
