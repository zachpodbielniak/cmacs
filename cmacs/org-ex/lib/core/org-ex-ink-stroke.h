/* org-ex-ink-stroke.h — Ink stroke data + S-expression I/O
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_INK_STROKE_H
#define ORG_EX_INK_STROKE_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib.h>
#include <glib-object.h>
#include "../org-ex-types.h"

G_BEGIN_DECLS

/* Tool that produced a stroke.  Finalised blocks contain only PEN
   strokes; ERASER strokes are transient hit-test paths kept in
   live-edit memory only. */
typedef enum
{
  ORG_EX_INK_TOOL_PEN,
  ORG_EX_INK_TOOL_ERASER,
  ORG_EX_INK_TOOL_HIGHLIGHTER  /* reserved for v2 */
} OrgExInkTool;

#define ORG_EX_TYPE_INK_TOOL (org_ex_ink_tool_get_type ())
GType org_ex_ink_tool_get_type (void) G_GNUC_CONST;

/* A captured sample.  X,Y are in the canvas coordinate space declared
   on the #+BEGIN_INK header (`:w` × `:h`).  PRESSURE is in [0.0, 1.0];
   1.0 means "no tablet / unknown", which renders flat. */
typedef struct
{
  gint16  x;
  gint16  y;
  gfloat  pressure;
} OrgExInkPoint;

#define ORG_EX_TYPE_INK_STROKE (org_ex_ink_stroke_get_type ())

/* Boxed type — refcounted opaque struct so callers don't need to know
   the internals.  Strokes are appended to and rendered from. */
typedef struct _OrgExInkStroke OrgExInkStroke;

GType org_ex_ink_stroke_get_type (void) G_GNUC_CONST;

OrgExInkStroke *org_ex_ink_stroke_new      (OrgExInkTool tool,
                                            const gchar *colour,
                                            gfloat       base_width);
OrgExInkStroke *org_ex_ink_stroke_ref      (OrgExInkStroke *self);
void            org_ex_ink_stroke_unref    (OrgExInkStroke *self);

void            org_ex_ink_stroke_append_point (OrgExInkStroke *self,
                                                gint16          x,
                                                gint16          y,
                                                gfloat          pressure);

OrgExInkTool         org_ex_ink_stroke_get_tool       (OrgExInkStroke *self);
const gchar *        org_ex_ink_stroke_get_colour     (OrgExInkStroke *self);
gfloat               org_ex_ink_stroke_get_base_width (OrgExInkStroke *self);
guint                org_ex_ink_stroke_n_points       (OrgExInkStroke *self);
const OrgExInkPoint *org_ex_ink_stroke_get_point      (OrgExInkStroke *self,
                                                       guint           index);
const OrgExInkPoint *org_ex_ink_stroke_get_points     (OrgExInkStroke *self,
                                                       guint          *n_points);

/* ---- Stroke array helpers ----
   GPtrArray of OrgExInkStroke* with full-ref destroy hooked up. */

GPtrArray *org_ex_ink_strokes_new   (void);
void       org_ex_ink_strokes_free  (GPtrArray *strokes);

/* ---- S-expression I/O ----
   The block-body language (one stroke per line, comments allowed):

       ;; cmacs-ink v1
       (s :t pen :c "#222" :w 2 :p ((123 245 850) (130 250 860)))

   Parser ignores `;;` lines and empty lines; rejects malformed
   strokes with a #G_IO_ERROR_FAILED.  Serialiser emits one stroke
   per line with stable key order so diffs stay minimal. */

GPtrArray *org_ex_ink_strokes_from_string (const gchar *text,
                                           GError     **error);

gchar     *org_ex_ink_strokes_to_string   (GPtrArray   *strokes);

G_END_DECLS

#endif /* ORG_EX_INK_STROKE_H */
