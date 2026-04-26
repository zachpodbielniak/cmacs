/* org-ex-ink-render.h — Strokes → SVG renderer
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_INK_RENDER_H
#define ORG_EX_INK_RENDER_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib.h>
#include "org-ex-ink-stroke.h"

G_BEGIN_DECLS

/* Render a stroke set to a self-contained SVG string.
   `width` and `height` are the canvas extent in pixels.  Pen strokes
   are emitted as variable-width <path> fragments split at pressure-
   change boundaries (Δwidth > 0.3 px); single-pressure strokes emit
   one <path>.  Eraser strokes are skipped — finalised SVG should
   never contain hit-test trails. */
gchar *org_ex_ink_render_to_svg (GPtrArray *strokes,
                                 gint       width,
                                 gint       height);

G_END_DECLS

#endif /* ORG_EX_INK_RENDER_H */
