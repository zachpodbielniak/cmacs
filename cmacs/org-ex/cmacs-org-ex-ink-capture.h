/* cmacs-org-ex-ink-capture.h — GTK3 modal ink capture window
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Live ink editor.  Opens a transient GTK3 toplevel with a Cairo
 * drawing area; reads pen / eraser / pressure off GdkDeviceTool +
 * GDK_AXIS_PRESSURE; runs a nested GMainLoop so the call returns
 * synchronously to the DEFUN that invoked it.
 *
 * No GTK / GDK headers leak through this interface — callers stay
 * agnostic of the toolkit.
 */

#ifndef CMACS_ORG_EX_INK_CAPTURE_H
#define CMACS_ORG_EX_INK_CAPTURE_H

#include <glib.h>
#include <cairo.h>

G_BEGIN_DECLS

/* Open the ink capture window.
 *
 * @initial: GPtrArray<OrgExInkStroke*> to seed the canvas (may be NULL).
 *           Captured pen strokes will be appended/diffed against this
 *           set; eraser strokes act as whole-stroke hit tests against
 *           the initial set.  The returned GPtrArray is a freshly
 *           allocated set with full-ref destroy hooked up — caller
 *           takes ownership.  Returns NULL only when @cancelled is
 *           set non-zero.
 *
 * @width, @height: canvas extent in pixels.
 *
 * @colour: hex colour for new pen strokes (e.g. "#222"; NULL → default).
 *
 * @base_width: default base width for new pen strokes (≤ 0 → default).
 *
 * @side_button_erases: if non-zero, holding side-button-1 turns a
 *           pen stroke into an eraser hit-test.  Provides eraser-end
 *           fallback for cheap pens.
 *
 * @cancelled: set to 1 if the user cancelled (Escape); 0 if they
 *           committed (Enter / Control-Return / window-close-via-OK).
 *           May be NULL if the caller doesn't care.
 */
GPtrArray *cmacs_org_ex_ink_capture (GPtrArray   *initial,
                                     gint         width,
                                     gint         height,
                                     const gchar *colour,
                                     gfloat       base_width,
                                     gboolean     side_button_erases,
                                     gboolean    *cancelled);

/* Same as cmacs_org_ex_ink_capture, but seeds the canvas with
 * BACKGROUND_SURFACE (typically a screenshot of an Emacs region from
 * cmacs-frame-screenshot-rect).  The surface is composited at the
 * canvas origin BEFORE strokes are drawn — the user effectively
 * draws on top of a still image of the source text.  Pass NULL to
 * fall back to the white-page default.
 */
GPtrArray *cmacs_org_ex_ink_capture_with_background (
                                     cairo_surface_t *background_surface,
                                     GPtrArray       *initial,
                                     gint             width,
                                     gint             height,
                                     const gchar     *colour,
                                     gfloat           base_width,
                                     gboolean         side_button_erases,
                                     gboolean        *cancelled);

/* Full-feature entry: all of the above plus
 *
 * @background_colour: a hex/named colour for the canvas page when
 *           BACKGROUND_SURFACE is NULL.  Used by `#+BEGIN_INK'
 *           canvas mode to theme-match the buffer's `default'
 *           face.  NULL → white.  IGNORED when BACKGROUND_SURFACE
 *           is non-NULL (screenshot wins).
 *
 * @default_tool: 0 = pen (default), 1 = highlighter, 2 = eraser.
 *           Seeds the toolbar's current selection.  User may
 *           override via the toolbar mid-session.
 *
 * @hilite_colour, @hilite_base_width: highlighter defaults.  NULL
 *           and ≤ 0 fall back to "#ffd700" / 12.0.
 */
GPtrArray *cmacs_org_ex_ink_capture_full (
                                     cairo_surface_t *background_surface,
                                     const gchar     *background_colour,
                                     GPtrArray       *initial,
                                     gint             width,
                                     gint             height,
                                     const gchar     *colour,
                                     gfloat           base_width,
                                     const gchar     *hilite_colour,
                                     gfloat           hilite_base_width,
                                     gint             default_tool,
                                     gboolean         side_button_erases,
                                     gboolean        *cancelled);

G_END_DECLS

#endif /* CMACS_ORG_EX_INK_CAPTURE_H */
