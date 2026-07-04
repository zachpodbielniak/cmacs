/* cmacs-imgedit-doc.h --- C-only image-document bridge API.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Plain-C wrapper around libregnum's LrgImageDocument / LrgImageLayer +
 * LrgImageCanvas drawing.  Like cmacs-libregnum-render.h, this header pulls
 * in NO libregnum / graylib / raylib types, so cmacs-internal sources (which
 * define a conflicting `Color' typedef) can include it freely.  The
 * implementation (cmacs-imgedit-doc.c) is the only imgedit TU that includes
 * <libregnum.h>. */

#ifndef CMACS_IMGEDIT_DOC_H
#define CMACS_IMGEDIT_DOC_H

#include <config.h>

#ifdef HAVE_CMACS_IMGEDIT

#include <glib.h>

/* Opaque handle wrapping an LrgImageDocument (+ scratch canvas). */
typedef struct CmacsImgeditDoc CmacsImgeditDoc;

/* Lifecycle. */
extern CmacsImgeditDoc *cmacs_imgedit_doc_new (int w, int h);
extern CmacsImgeditDoc *cmacs_imgedit_doc_new_from_file (const char *path,
                                                         char **error_msg);
extern void cmacs_imgedit_doc_free (CmacsImgeditDoc *d);

extern int cmacs_imgedit_doc_width  (CmacsImgeditDoc *d);
extern int cmacs_imgedit_doc_height (CmacsImgeditDoc *d);

/* Layers (index 0 == bottom). */
extern guint cmacs_imgedit_doc_n_layers (CmacsImgeditDoc *d);
extern guint cmacs_imgedit_doc_add_layer (CmacsImgeditDoc *d, const char *name);
extern gint  cmacs_imgedit_doc_add_layer_from_file (CmacsImgeditDoc *d,
                                                    const char *path,
                                                    const char *name,
                                                    char **error_msg);
/* Add a layer from raw RGBA8 pixels (paste / screenshot).  Returns index. */
extern gint  cmacs_imgedit_doc_add_layer_rgba (CmacsImgeditDoc *d,
                                               int w, int h,
                                               const guint8 *rgba, gsize n,
                                               const char *name);
extern gboolean cmacs_imgedit_doc_remove_layer (CmacsImgeditDoc *d, guint idx);
extern gboolean cmacs_imgedit_doc_move_layer (CmacsImgeditDoc *d,
                                              guint from, guint to);
extern gint  cmacs_imgedit_doc_duplicate_layer (CmacsImgeditDoc *d, guint idx);

extern guint cmacs_imgedit_doc_active (CmacsImgeditDoc *d);
extern void  cmacs_imgedit_doc_set_active (CmacsImgeditDoc *d, guint idx);

/* PATH/NAME borrowed; valid until the next layer mutation. */
extern const char *cmacs_imgedit_doc_layer_name (CmacsImgeditDoc *d, guint idx);
extern void   cmacs_imgedit_doc_set_layer_name (CmacsImgeditDoc *d, guint idx,
                                                const char *name);
extern double cmacs_imgedit_doc_layer_opacity (CmacsImgeditDoc *d, guint idx);
extern void   cmacs_imgedit_doc_set_layer_opacity (CmacsImgeditDoc *d,
                                                   guint idx, double o);
/* Blend mode == GrlImageBlendMode int: 0 replace,1 over,2 add,3 multiply,
 * 4 subtract. */
extern gint   cmacs_imgedit_doc_layer_blend (CmacsImgeditDoc *d, guint idx);
extern void   cmacs_imgedit_doc_set_layer_blend (CmacsImgeditDoc *d, guint idx,
                                                 gint mode);
extern gboolean cmacs_imgedit_doc_layer_visible (CmacsImgeditDoc *d, guint idx);
extern void   cmacs_imgedit_doc_set_layer_visible (CmacsImgeditDoc *d,
                                                   guint idx, gboolean v);
extern void   cmacs_imgedit_doc_layer_offset (CmacsImgeditDoc *d, guint idx,
                                              int *x, int *y);
extern void   cmacs_imgedit_doc_set_layer_offset (CmacsImgeditDoc *d, guint idx,
                                                  int x, int y);

/* Editing on the ACTIVE layer.  Colours are RGBA bytes 0..255.  All set the
 * document dirty.  Callers should cmacs_imgedit_doc_push_undo() first if the
 * op should be undoable. */
extern void cmacs_imgedit_doc_fill (CmacsImgeditDoc *d,
                                    guint8 r, guint8 g, guint8 b, guint8 a);
extern void cmacs_imgedit_doc_set_pixel (CmacsImgeditDoc *d, int x, int y,
                                         guint8 r, guint8 g, guint8 b,
                                         guint8 a);
/* Set the current draw colour used by the shape tools (line/rect/circle). */
extern void cmacs_imgedit_doc_set_color (CmacsImgeditDoc *d,
                                         guint8 r, guint8 g, guint8 b,
                                         guint8 a);
extern void cmacs_imgedit_doc_draw_line (CmacsImgeditDoc *d,
                                         int x1, int y1, int x2, int y2,
                                         int thickness);
extern void cmacs_imgedit_doc_draw_rect (CmacsImgeditDoc *d,
                                         int x, int y, int w, int h,
                                         gboolean filled, int thickness);
extern void cmacs_imgedit_doc_draw_circle (CmacsImgeditDoc *d,
                                           int cx, int cy, int radius,
                                           gboolean filled, int thickness);
/* Annotation shapes: arrow (shaft + filled head), ellipse, text.
   Text renders with the embedded bitmap-font fallback when headless. */
extern void cmacs_imgedit_doc_draw_arrow (CmacsImgeditDoc *d,
                                          int x1, int y1, int x2, int y2,
                                          int thickness);
extern void cmacs_imgedit_doc_draw_ellipse (CmacsImgeditDoc *d,
                                            int cx, int cy, int rx, int ry,
                                            gboolean filled, int thickness);
extern void cmacs_imgedit_doc_draw_text (CmacsImgeditDoc *d, int x, int y,
                                         const char *text, int size);
extern void cmacs_imgedit_doc_flood_fill (CmacsImgeditDoc *d, int x, int y,
                                          guint8 r, guint8 g, guint8 b,
                                          guint8 a, int tolerance);

/* Read the flattened (composited) pixel at (X,Y).  FALSE if out of bounds. */
extern gboolean cmacs_imgedit_doc_get_pixel (CmacsImgeditDoc *d, int x, int y,
                                             guint8 *r, guint8 *g, guint8 *b,
                                             guint8 *a);

/* Set the per-layer blend mode + opacity scratch state used by drawing. */
extern void cmacs_imgedit_doc_set_draw_blend (CmacsImgeditDoc *d, gint mode);

/* Undo / redo (active-layer pixel snapshots). */
extern void     cmacs_imgedit_doc_push_undo (CmacsImgeditDoc *d);
extern gboolean cmacs_imgedit_doc_undo (CmacsImgeditDoc *d);
extern gboolean cmacs_imgedit_doc_redo (CmacsImgeditDoc *d);
extern gboolean cmacs_imgedit_doc_can_undo (CmacsImgeditDoc *d);
extern gboolean cmacs_imgedit_doc_can_redo (CmacsImgeditDoc *d);

/* I/O. */
extern gboolean cmacs_imgedit_doc_export (CmacsImgeditDoc *d, const char *path,
                                          char **error_msg);
/* Flatten + encode to PNG bytes (g_malloc'd; caller g_free's).  NULL on err. */
extern guint8  *cmacs_imgedit_doc_export_png_bytes (CmacsImgeditDoc *d,
                                                    gsize *out_n);

/* Borrowed pointer to the flattened RGBA8 buffer (w*h*4); for GPU upload by
 * the viewport.  Valid until the next edit/flatten. */
extern const guint8 *cmacs_imgedit_doc_flatten_pixels (CmacsImgeditDoc *d,
                                                       int *w, int *h);

/* Borrowed LrgImageDocument* (as void*) for the render bridge image mode. */
extern void *cmacs_imgedit_doc_document (CmacsImgeditDoc *d);

#endif /* HAVE_CMACS_IMGEDIT */
#endif /* CMACS_IMGEDIT_DOC_H */
