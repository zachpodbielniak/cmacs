/* cmacs-imgedit-defuns.c --- Image-editor Lisp primitives.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The DEFUN surface for the 2D image / sprite editor.  Each document is held
 * in a small C registry and referenced from Lisp by an integer handle, so no
 * Lisp_Object is stored in GLib-allocated memory (GC-safe).  This TU includes
 * lisp.h and the plain-C bridge header ONLY (never <libregnum.h>), so raylib's
 * `Color' typedef cannot collide with cmacs internals. */

#include <config.h>

#ifdef HAVE_CMACS_IMGEDIT

#include "lisp.h"
#include "coding.h"             /* ENCODE_UTF_8 for the text tool */
#include "buffer.h"             /* CHECK_BUFFER for viewport-bind */
#include "cmacs-imgedit-doc.h"
#include "cmacs-imgedit-clip.h"
#ifdef HAVE_CMACS_LIBREGNUM
/* Firewall-safe (raylib-free, opaque-ctx) headers for the live viewport. */
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#endif

/* Qcmacs_imgedit_error is DEFSYM'd in syms_of_* below; make-docfile generates
   its global slot, so it must NOT be declared as a file-local variable. */

/* Registry: handle == index; a NULL slot is free/closed. */
static GPtrArray *imgedit_registry;

static EMACS_INT
ie_register (CmacsImgeditDoc *d)
{
  guint i;

  if (imgedit_registry == NULL)
    imgedit_registry = g_ptr_array_new ();
  for (i = 0; i < imgedit_registry->len; i++)
    if (g_ptr_array_index (imgedit_registry, i) == NULL)
      {
        imgedit_registry->pdata[i] = d;
        return (EMACS_INT) i;
      }
  g_ptr_array_add (imgedit_registry, d);
  return (EMACS_INT) (imgedit_registry->len - 1);
}

static CmacsImgeditDoc *
ie_lookup (Lisp_Object handle)
{
  EMACS_INT h;
  CmacsImgeditDoc *d;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (imgedit_registry == NULL || h < 0
      || h >= (EMACS_INT) imgedit_registry->len)
    xsignal2 (Qcmacs_imgedit_error,
              build_string ("unknown or closed cmacs-imgedit handle"), handle);
  d = g_ptr_array_index (imgedit_registry, h);
  if (d == NULL)
    xsignal2 (Qcmacs_imgedit_error,
              build_string ("unknown or closed cmacs-imgedit handle"), handle);
  return d;
}

static guint8
ie_clamp8 (Lisp_Object v)
{
  EMACS_INT x = INTEGERP (v) ? XFIXNUM (v) : 0;
  return (guint8) (x < 0 ? 0 : (x > 255 ? 255 : x));
}

static int
ie_int (Lisp_Object v, int dflt)
{
  return INTEGERP (v) ? (int) XFIXNUM (v) : dflt;
}

static double
ie_dbl (Lisp_Object v, double dflt)
{
  return NUMBERP (v) ? XFLOATINT (v) : dflt;
}

static const char *
ie_opt_str (Lisp_Object v)
{
  return STRINGP (v) ? SSDATA (v) : NULL;
}

DEFUN ("cmacs-imgedit-supported-p", Fcmacs_imgedit_supported_p,
       Scmacs_imgedit_supported_p, 0, 0, 0,
       doc: /* Return non-nil if cmacs was built with --with-cmacs-imgedit.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-imgedit-new", Fcmacs_imgedit_new, Scmacs_imgedit_new, 2, 2, 0,
       doc: /* Create a WIDTH x HEIGHT image document and return its handle.  */)
  (Lisp_Object width, Lisp_Object height)
{
  CmacsImgeditDoc *d;

  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);
  d = cmacs_imgedit_doc_new ((int) XFIXNUM (width), (int) XFIXNUM (height));
  if (d == NULL)
    xsignal1 (Qcmacs_imgedit_error,
              build_string ("invalid image dimensions"));
  return make_fixnum (ie_register (d));
}

DEFUN ("cmacs-imgedit-open", Fcmacs_imgedit_open, Scmacs_imgedit_open, 1, 1, 0,
       doc: /* Load image file PATH into a new document; return its handle.  */)
  (Lisp_Object path)
{
  CmacsImgeditDoc *d;
  char *err = NULL;

  CHECK_STRING (path);
  d = cmacs_imgedit_doc_new_from_file (SSDATA (path), &err);
  if (d == NULL)
    {
      Lisp_Object msg = build_string (err ? err : "could not open image");
      g_free (err);
      xsignal1 (Qcmacs_imgedit_error, msg);
    }
  return make_fixnum (ie_register (d));
}

DEFUN ("cmacs-imgedit-free", Fcmacs_imgedit_free, Scmacs_imgedit_free, 1, 1, 0,
       doc: /* Free the document referenced by HANDLE.  */)
  (Lisp_Object handle)
{
  EMACS_INT h;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (imgedit_registry != NULL && h >= 0
      && h < (EMACS_INT) imgedit_registry->len)
    {
      CmacsImgeditDoc *d = g_ptr_array_index (imgedit_registry, h);
      if (d != NULL)
        {
          cmacs_imgedit_doc_free (d);
          imgedit_registry->pdata[h] = NULL;
        }
    }
  return Qnil;
}

DEFUN ("cmacs-imgedit-width", Fcmacs_imgedit_width, Scmacs_imgedit_width,
       1, 1, 0, doc: /* Document width in pixels.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_imgedit_doc_width (ie_lookup (handle)));
}

DEFUN ("cmacs-imgedit-height", Fcmacs_imgedit_height, Scmacs_imgedit_height,
       1, 1, 0, doc: /* Document height in pixels.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_imgedit_doc_height (ie_lookup (handle)));
}

DEFUN ("cmacs-imgedit-save", Fcmacs_imgedit_save, Scmacs_imgedit_save, 2, 2, 0,
       doc: /* Flatten and write the document to PATH (format by extension).  */)
  (Lisp_Object handle, Lisp_Object path)
{
  char *err = NULL;

  CHECK_STRING (path);
  if (!cmacs_imgedit_doc_export (ie_lookup (handle), SSDATA (path), &err))
    {
      Lisp_Object msg = build_string (err ? err : "save failed");
      g_free (err);
      xsignal1 (Qcmacs_imgedit_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-imgedit-export-png-bytes", Fcmacs_imgedit_export_png_bytes,
       Scmacs_imgedit_export_png_bytes, 1, 1, 0,
       doc: /* Return the flattened document as a unibyte PNG string.  */)
  (Lisp_Object handle)
{
  gsize n = 0;
  guint8 *bytes = cmacs_imgedit_doc_export_png_bytes (ie_lookup (handle), &n);
  Lisp_Object res;

  if (bytes == NULL || n == 0)
    {
      g_free (bytes);
      xsignal1 (Qcmacs_imgedit_error, build_string ("PNG encode failed"));
    }
  res = make_unibyte_string ((const char *) bytes, (ptrdiff_t) n);
  g_free (bytes);
  return res;
}

DEFUN ("cmacs-imgedit-n-layers", Fcmacs_imgedit_n_layers,
       Scmacs_imgedit_n_layers, 1, 1, 0, doc: /* Number of layers.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_imgedit_doc_n_layers (ie_lookup (handle)));
}

DEFUN ("cmacs-imgedit-add-layer", Fcmacs_imgedit_add_layer,
       Scmacs_imgedit_add_layer, 1, 2, 0,
       doc: /* Append a transparent layer (optional NAME); return its index.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  return make_fixnum (cmacs_imgedit_doc_add_layer (ie_lookup (handle),
                                                   ie_opt_str (name)));
}

DEFUN ("cmacs-imgedit-add-layer-from-file", Fcmacs_imgedit_add_layer_from_file,
       Scmacs_imgedit_add_layer_from_file, 2, 3, 0,
       doc: /* Append a layer loaded from PATH (optional NAME); return index.  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object name)
{
  char *err = NULL;
  gint idx;

  CHECK_STRING (path);
  idx = cmacs_imgedit_doc_add_layer_from_file (ie_lookup (handle),
                                               SSDATA (path),
                                               ie_opt_str (name), &err);
  if (idx < 0)
    {
      Lisp_Object msg = build_string (err ? err : "could not load layer");
      g_free (err);
      xsignal1 (Qcmacs_imgedit_error, msg);
    }
  return make_fixnum (idx);
}

DEFUN ("cmacs-imgedit-add-layer-rgba", Fcmacs_imgedit_add_layer_rgba,
       Scmacs_imgedit_add_layer_rgba, 4, 5, 0,
       doc: /* Append a layer from raw RGBA8 DATA of WIDTH x HEIGHT.
DATA is a unibyte string of WIDTH*HEIGHT*4 bytes.  Return the new index.  */)
  (Lisp_Object handle, Lisp_Object width, Lisp_Object height,
   Lisp_Object data, Lisp_Object name)
{
  gint idx;

  CHECK_FIXNUM (width);
  CHECK_FIXNUM (height);
  CHECK_STRING (data);
  idx = cmacs_imgedit_doc_add_layer_rgba (ie_lookup (handle),
                                          (int) XFIXNUM (width),
                                          (int) XFIXNUM (height),
                                          SDATA (data), SBYTES (data),
                                          ie_opt_str (name));
  if (idx < 0)
    xsignal1 (Qcmacs_imgedit_error, build_string ("invalid RGBA layer data"));
  return make_fixnum (idx);
}

DEFUN ("cmacs-imgedit-remove-layer", Fcmacs_imgedit_remove_layer,
       Scmacs_imgedit_remove_layer, 2, 2, 0,
       doc: /* Remove layer INDEX (refused if it is the only layer).  */)
  (Lisp_Object handle, Lisp_Object index)
{
  CHECK_FIXNUM (index);
  return cmacs_imgedit_doc_remove_layer (ie_lookup (handle),
                                         (guint) XFIXNUM (index)) ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-move-layer", Fcmacs_imgedit_move_layer,
       Scmacs_imgedit_move_layer, 3, 3, 0,
       doc: /* Move layer FROM to index TO.  */)
  (Lisp_Object handle, Lisp_Object from, Lisp_Object to)
{
  CHECK_FIXNUM (from);
  CHECK_FIXNUM (to);
  return cmacs_imgedit_doc_move_layer (ie_lookup (handle),
                                       (guint) XFIXNUM (from),
                                       (guint) XFIXNUM (to)) ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-duplicate-layer", Fcmacs_imgedit_duplicate_layer,
       Scmacs_imgedit_duplicate_layer, 2, 2, 0,
       doc: /* Duplicate layer INDEX; return the new layer's index.  */)
  (Lisp_Object handle, Lisp_Object index)
{
  CHECK_FIXNUM (index);
  return make_fixnum (cmacs_imgedit_doc_duplicate_layer (
                          ie_lookup (handle), (guint) XFIXNUM (index)));
}

DEFUN ("cmacs-imgedit-active-layer", Fcmacs_imgedit_active_layer,
       Scmacs_imgedit_active_layer, 1, 1, 0,
       doc: /* Index of the active layer.  */)
  (Lisp_Object handle)
{
  return make_fixnum (cmacs_imgedit_doc_active (ie_lookup (handle)));
}

DEFUN ("cmacs-imgedit-set-active-layer", Fcmacs_imgedit_set_active_layer,
       Scmacs_imgedit_set_active_layer, 2, 2, 0,
       doc: /* Make layer INDEX active.  */)
  (Lisp_Object handle, Lisp_Object index)
{
  CHECK_FIXNUM (index);
  cmacs_imgedit_doc_set_active (ie_lookup (handle), (guint) XFIXNUM (index));
  return Qnil;
}

DEFUN ("cmacs-imgedit-layer-name", Fcmacs_imgedit_layer_name,
       Scmacs_imgedit_layer_name, 2, 2, 0, doc: /* Name of layer INDEX.  */)
  (Lisp_Object handle, Lisp_Object index)
{
  const char *n;

  CHECK_FIXNUM (index);
  n = cmacs_imgedit_doc_layer_name (ie_lookup (handle),
                                    (guint) XFIXNUM (index));
  return n ? build_string (n) : Qnil;
}

DEFUN ("cmacs-imgedit-set-layer-name", Fcmacs_imgedit_set_layer_name,
       Scmacs_imgedit_set_layer_name, 3, 3, 0,
       doc: /* Set NAME of layer INDEX.  */)
  (Lisp_Object handle, Lisp_Object index, Lisp_Object name)
{
  CHECK_FIXNUM (index);
  CHECK_STRING (name);
  cmacs_imgedit_doc_set_layer_name (ie_lookup (handle),
                                    (guint) XFIXNUM (index), SSDATA (name));
  return Qnil;
}

DEFUN ("cmacs-imgedit-layer-opacity", Fcmacs_imgedit_layer_opacity,
       Scmacs_imgedit_layer_opacity, 2, 2, 0,
       doc: /* Opacity (0.0..1.0) of layer INDEX.  */)
  (Lisp_Object handle, Lisp_Object index)
{
  CHECK_FIXNUM (index);
  return make_float (cmacs_imgedit_doc_layer_opacity (
                         ie_lookup (handle), (guint) XFIXNUM (index)));
}

DEFUN ("cmacs-imgedit-set-layer-opacity", Fcmacs_imgedit_set_layer_opacity,
       Scmacs_imgedit_set_layer_opacity, 3, 3, 0,
       doc: /* Set OPACITY (0.0..1.0) of layer INDEX.  */)
  (Lisp_Object handle, Lisp_Object index, Lisp_Object opacity)
{
  double o;

  CHECK_FIXNUM (index);
  o = FLOATP (opacity) ? XFLOAT_DATA (opacity)
                       : (INTEGERP (opacity) ? (double) XFIXNUM (opacity) : 1.0);
  cmacs_imgedit_doc_set_layer_opacity (ie_lookup (handle),
                                       (guint) XFIXNUM (index), o);
  return Qnil;
}

DEFUN ("cmacs-imgedit-layer-blend", Fcmacs_imgedit_layer_blend,
       Scmacs_imgedit_layer_blend, 2, 2, 0,
       doc: /* Blend mode of layer INDEX (0 replace,1 over,2 add,3 multiply,
4 subtract).  */)
  (Lisp_Object handle, Lisp_Object index)
{
  CHECK_FIXNUM (index);
  return make_fixnum (cmacs_imgedit_doc_layer_blend (
                          ie_lookup (handle), (guint) XFIXNUM (index)));
}

DEFUN ("cmacs-imgedit-set-layer-blend", Fcmacs_imgedit_set_layer_blend,
       Scmacs_imgedit_set_layer_blend, 3, 3, 0,
       doc: /* Set blend MODE of layer INDEX.  */)
  (Lisp_Object handle, Lisp_Object index, Lisp_Object mode)
{
  CHECK_FIXNUM (index);
  CHECK_FIXNUM (mode);
  cmacs_imgedit_doc_set_layer_blend (ie_lookup (handle),
                                     (guint) XFIXNUM (index),
                                     (gint) XFIXNUM (mode));
  return Qnil;
}

DEFUN ("cmacs-imgedit-layer-visible-p", Fcmacs_imgedit_layer_visible_p,
       Scmacs_imgedit_layer_visible_p, 2, 2, 0,
       doc: /* Whether layer INDEX is visible.  */)
  (Lisp_Object handle, Lisp_Object index)
{
  CHECK_FIXNUM (index);
  return cmacs_imgedit_doc_layer_visible (ie_lookup (handle),
                                          (guint) XFIXNUM (index)) ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-set-layer-visible", Fcmacs_imgedit_set_layer_visible,
       Scmacs_imgedit_set_layer_visible, 3, 3, 0,
       doc: /* Set whether layer INDEX is VISIBLE.  */)
  (Lisp_Object handle, Lisp_Object index, Lisp_Object visible)
{
  CHECK_FIXNUM (index);
  cmacs_imgedit_doc_set_layer_visible (ie_lookup (handle),
                                       (guint) XFIXNUM (index),
                                       NILP (visible) ? FALSE : TRUE);
  return Qnil;
}

DEFUN ("cmacs-imgedit-layer-locked-p", Fcmacs_imgedit_layer_locked_p,
       Scmacs_imgedit_layer_locked_p, 2, 2, 0,
       doc: /* Return t if layer INDEX of HANDLE is locked.  */)
  (Lisp_Object handle, Lisp_Object index)
{
  return cmacs_imgedit_doc_layer_locked (ie_lookup (handle), ie_int (index, 0))
         ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-set-layer-locked", Fcmacs_imgedit_set_layer_locked,
       Scmacs_imgedit_set_layer_locked, 3, 3, 0,
       doc: /* Lock (LOCKED non-nil) or unlock layer INDEX of HANDLE.
A locked layer refuses edits until unlocked.  */)
  (Lisp_Object handle, Lisp_Object index, Lisp_Object locked)
{
  cmacs_imgedit_doc_set_layer_locked (ie_lookup (handle), ie_int (index, 0),
                                      !NILP (locked));
  return Qnil;
}

DEFUN ("cmacs-imgedit-set-layer-offset", Fcmacs_imgedit_set_layer_offset,
       Scmacs_imgedit_set_layer_offset, 4, 4, 0,
       doc: /* Set the X,Y offset of layer INDEX within the document.  */)
  (Lisp_Object handle, Lisp_Object index, Lisp_Object x, Lisp_Object y)
{
  CHECK_FIXNUM (index);
  cmacs_imgedit_doc_set_layer_offset (ie_lookup (handle),
                                      (guint) XFIXNUM (index),
                                      ie_int (x, 0), ie_int (y, 0));
  return Qnil;
}

DEFUN ("cmacs-imgedit-set-draw-blend", Fcmacs_imgedit_set_draw_blend,
       Scmacs_imgedit_set_draw_blend, 2, 2, 0,
       doc: /* Set the blend MODE used by drawing tools (line/rect/circle).  */)
  (Lisp_Object handle, Lisp_Object mode)
{
  CHECK_FIXNUM (mode);
  cmacs_imgedit_doc_set_draw_blend (ie_lookup (handle), (gint) XFIXNUM (mode));
  return Qnil;
}

DEFUN ("cmacs-imgedit-fill", Fcmacs_imgedit_fill, Scmacs_imgedit_fill, 5, 5, 0,
       doc: /* Fill the active layer with colour R G B A (0..255).  */)
  (Lisp_Object handle, Lisp_Object r, Lisp_Object g, Lisp_Object b,
   Lisp_Object a)
{
  cmacs_imgedit_doc_fill (ie_lookup (handle), ie_clamp8 (r), ie_clamp8 (g),
                          ie_clamp8 (b), ie_clamp8 (a));
  return Qnil;
}

DEFUN ("cmacs-imgedit-set-pixel", Fcmacs_imgedit_set_pixel,
       Scmacs_imgedit_set_pixel, 7, 7, 0,
       doc: /* Set pixel X,Y of the active layer to R G B A.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object r,
   Lisp_Object g, Lisp_Object b, Lisp_Object a)
{
  cmacs_imgedit_doc_set_pixel (ie_lookup (handle), ie_int (x, 0),
                               ie_int (y, 0), ie_clamp8 (r), ie_clamp8 (g),
                               ie_clamp8 (b), ie_clamp8 (a));
  return Qnil;
}

DEFUN ("cmacs-imgedit-set-color", Fcmacs_imgedit_set_color,
       Scmacs_imgedit_set_color, 5, 5, 0,
       doc: /* Set the current draw colour R G B A used by the shape tools.  */)
  (Lisp_Object handle, Lisp_Object r, Lisp_Object g, Lisp_Object b,
   Lisp_Object a)
{
  cmacs_imgedit_doc_set_color (ie_lookup (handle), ie_clamp8 (r),
                               ie_clamp8 (g), ie_clamp8 (b), ie_clamp8 (a));
  return Qnil;
}

DEFUN ("cmacs-imgedit-draw-line", Fcmacs_imgedit_draw_line,
       Scmacs_imgedit_draw_line, 6, 6, 0,
       doc: /* Draw a line X1 Y1 -> X2 Y2 with THICKNESS px in the current
draw colour (see `cmacs-imgedit-set-color').  */)
  (Lisp_Object handle, Lisp_Object x1, Lisp_Object y1, Lisp_Object x2,
   Lisp_Object y2, Lisp_Object thickness)
{
  cmacs_imgedit_doc_draw_line (ie_lookup (handle), ie_int (x1, 0),
                               ie_int (y1, 0), ie_int (x2, 0), ie_int (y2, 0),
                               ie_int (thickness, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-draw-rect", Fcmacs_imgedit_draw_rect,
       Scmacs_imgedit_draw_rect, 7, 7, 0,
       doc: /* Draw a rectangle X Y W H in the current draw colour.  FILLED
non-nil fills it, else stroke it with THICKNESS.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object w,
   Lisp_Object h, Lisp_Object filled, Lisp_Object thickness)
{
  cmacs_imgedit_doc_draw_rect (ie_lookup (handle), ie_int (x, 0),
                               ie_int (y, 0), ie_int (w, 0), ie_int (h, 0),
                               NILP (filled) ? FALSE : TRUE,
                               ie_int (thickness, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-draw-circle", Fcmacs_imgedit_draw_circle,
       Scmacs_imgedit_draw_circle, 6, 6, 0,
       doc: /* Draw a circle centred CX CY, RADIUS px, in the current draw
colour.  FILLED non-nil fills, else strokes with THICKNESS.  */)
  (Lisp_Object handle, Lisp_Object cx, Lisp_Object cy, Lisp_Object radius,
   Lisp_Object filled, Lisp_Object thickness)
{
  cmacs_imgedit_doc_draw_circle (ie_lookup (handle), ie_int (cx, 0),
                                 ie_int (cy, 0), ie_int (radius, 1),
                                 NILP (filled) ? FALSE : TRUE,
                                 ie_int (thickness, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-draw-arrow", Fcmacs_imgedit_draw_arrow,
       Scmacs_imgedit_draw_arrow, 5, 6, 0,
       doc: /* Draw an arrow from X1,Y1 to X2,Y2 in the current draw colour.
The head (a filled triangle sized from THICKNESS) sits at X2,Y2.  */)
  (Lisp_Object handle, Lisp_Object x1, Lisp_Object y1, Lisp_Object x2,
   Lisp_Object y2, Lisp_Object thickness)
{
  cmacs_imgedit_doc_draw_arrow (ie_lookup (handle), ie_int (x1, 0),
                                ie_int (y1, 0), ie_int (x2, 0),
                                ie_int (y2, 0), ie_int (thickness, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-draw-ellipse", Fcmacs_imgedit_draw_ellipse,
       Scmacs_imgedit_draw_ellipse, 5, 7, 0,
       doc: /* Draw an ellipse centred CX CY with radii RX RY in the current
draw colour.  FILLED non-nil fills, else strokes with THICKNESS.  */)
  (Lisp_Object handle, Lisp_Object cx, Lisp_Object cy, Lisp_Object rx,
   Lisp_Object ry, Lisp_Object filled, Lisp_Object thickness)
{
  cmacs_imgedit_doc_draw_ellipse (ie_lookup (handle), ie_int (cx, 0),
                                  ie_int (cy, 0), ie_int (rx, 1),
                                  ie_int (ry, 1),
                                  NILP (filled) ? FALSE : TRUE,
                                  ie_int (thickness, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-draw-text", Fcmacs_imgedit_draw_text,
       Scmacs_imgedit_draw_text, 4, 5, 0,
       doc: /* Draw TEXT at X,Y in the current draw colour.
SIZE is the font height in pixels (default 16).  Renders with the
engine's TrueType font, or its embedded bitmap font when headless.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object text,
   Lisp_Object size)
{
  CHECK_STRING (text);
  cmacs_imgedit_doc_draw_text (ie_lookup (handle), ie_int (x, 0),
                               ie_int (y, 0),
                               SSDATA (ENCODE_UTF_8 (text)),
                               ie_int (size, 16));
  return Qnil;
}

DEFUN ("cmacs-imgedit-viewport-bind", Fcmacs_imgedit_viewport_bind,
       Scmacs_imgedit_viewport_bind, 2, 2, 0,
       doc: /* Bind image HANDLE's document into BUFFER's libregnum view for
zero-copy live display (the render side re-flattens it each refresh).  Returns
t on success, nil if the viewport is unavailable.  */)
  (Lisp_Object handle, Lisp_Object buffer)
{
#ifdef HAVE_CMACS_LIBREGNUM
  CmacsImgeditDoc *d = ie_lookup (handle);
  void *doc = d ? cmacs_imgedit_doc_document (d) : NULL;
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  v = cmacs_libregnum_view_for_buffer (buffer);
  ctx = v ? cmacs_libregnum_view_get_render_ctx (v) : NULL;
  if (ctx && doc)
    {
      cmacs_libregnum_render_ctx_image_set_document (ctx, doc);
      cmacs_libregnum_view_request_redraw (v);
      return Qt;
    }
#else
  (void) handle; (void) buffer;
#endif
  return Qnil;
}

DEFUN ("cmacs-imgedit-clipboard-available-p",
       Fcmacs_imgedit_clipboard_available_p,
       Scmacs_imgedit_clipboard_available_p, 0, 0, 0,
       doc: /* Return t when the in-process GTK image clipboard is usable.
Non-nil under a pgtk session (any Wayland compositor or X11); nil under
--lrg / tty, where callers fall back to wl-clipboard.  */)
  (void)
{
  return cmacs_imgedit_clip_available () ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-clipboard-set-png", Fcmacs_imgedit_clipboard_set_png,
       Scmacs_imgedit_clipboard_set_png, 1, 1, 0,
       doc: /* Put PNG-BYTES (a unibyte string) on the clipboard as an image.
Uses Emacs's own GTK clipboard, so it works under gowl, GNOME/Mutter, KDE
or X11 alike.  Signals on failure.  */)
  (Lisp_Object png_bytes)
{
  char *err = NULL;

  CHECK_STRING (png_bytes);
  if (!cmacs_imgedit_clip_set_png ((const guint8 *) SDATA (png_bytes),
                                   (gsize) SBYTES (png_bytes), &err))
    {
      Lisp_Object msg = build_string (err ? err : "clipboard set failed");
      g_free (err);
      xsignal1 (Qcmacs_imgedit_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-imgedit-clipboard-get-png", Fcmacs_imgedit_clipboard_get_png,
       Scmacs_imgedit_clipboard_get_png, 0, 0, 0,
       doc: /* Return the clipboard image as a unibyte PNG string, or nil.
nil when the GTK clipboard is unavailable or holds no image (callers then
fall back to wl-paste).  */)
  (void)
{
  gsize n = 0;
  guint8 *bytes;
  Lisp_Object res;

  bytes = cmacs_imgedit_clip_get_png (&n, NULL);
  if (bytes == NULL || n == 0)
    {
      g_free (bytes);
      return Qnil;
    }
  res = make_unibyte_string ((const char *) bytes, (ptrdiff_t) n);
  g_free (bytes);
  return res;
}

DEFUN ("cmacs-imgedit-flood-fill", Fcmacs_imgedit_flood_fill,
       Scmacs_imgedit_flood_fill, 8, 8, 0,
       doc: /* Flood-fill the active layer from X,Y with R G B A, TOLERANCE.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object r,
   Lisp_Object g, Lisp_Object b, Lisp_Object a, Lisp_Object tolerance)
{
  cmacs_imgedit_doc_flood_fill (ie_lookup (handle), ie_int (x, 0),
                                ie_int (y, 0), ie_clamp8 (r), ie_clamp8 (g),
                                ie_clamp8 (b), ie_clamp8 (a),
                                ie_int (tolerance, 0));
  return Qnil;
}

DEFUN ("cmacs-imgedit-flip", Fcmacs_imgedit_flip, Scmacs_imgedit_flip, 1, 2, 0,
       doc: /* Flip HANDLE's whole document; HORIZONTAL non-nil = left-right.  */)
  (Lisp_Object handle, Lisp_Object horizontal)
{
  cmacs_imgedit_doc_flip (ie_lookup (handle), !NILP (horizontal));
  return Qnil;
}

DEFUN ("cmacs-imgedit-resize", Fcmacs_imgedit_resize, Scmacs_imgedit_resize,
       3, 4, 0,
       doc: /* Resize the whole document to WIDTH x HEIGHT.
NEAREST non-nil uses nearest-neighbour (crisp for pixel art).  */)
  (Lisp_Object handle, Lisp_Object width, Lisp_Object height,
   Lisp_Object nearest)
{
  CHECK_FIXNAT (width); CHECK_FIXNAT (height);
  cmacs_imgedit_doc_resize (ie_lookup (handle), XFIXNUM (width),
                            XFIXNUM (height), !NILP (nearest));
  return Qnil;
}

DEFUN ("cmacs-imgedit-crop", Fcmacs_imgedit_crop, Scmacs_imgedit_crop, 5, 5, 0,
       doc: /* Crop the whole document to the rectangle X Y WIDTH HEIGHT.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object width,
   Lisp_Object height)
{
  cmacs_imgedit_doc_crop (ie_lookup (handle), ie_int (x, 0), ie_int (y, 0),
                          ie_int (width, 1), ie_int (height, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-rotate", Fcmacs_imgedit_rotate, Scmacs_imgedit_rotate,
       1, 2, 0,
       doc: /* Rotate the whole document 90 degrees; CLOCKWISE non-nil = CW.  */)
  (Lisp_Object handle, Lisp_Object clockwise)
{
  cmacs_imgedit_doc_rotate (ie_lookup (handle), !NILP (clockwise));
  return Qnil;
}

DEFUN ("cmacs-imgedit-gradient", Fcmacs_imgedit_gradient,
       Scmacs_imgedit_gradient, 3, 4, 0,
       doc: /* Fill the active layer with a gradient from colour A to B.
A and B are (R G B A) lists.  RADIAL non-nil draws a radial gradient from the
centre; otherwise a linear gradient (VERTICAL non-nil = top-to-bottom).  */)
  (Lisp_Object handle, Lisp_Object a, Lisp_Object b, Lisp_Object radial)
{
  gboolean vertical = FALSE;   /* linear axis; radial ignores it */
  cmacs_imgedit_doc_gradient
    (ie_lookup (handle), !NILP (radial), vertical,
     ie_clamp8 (Fnth (make_fixnum (0), a)), ie_clamp8 (Fnth (make_fixnum (1), a)),
     ie_clamp8 (Fnth (make_fixnum (2), a)), ie_clamp8 (Fnth (make_fixnum (3), a)),
     ie_clamp8 (Fnth (make_fixnum (0), b)), ie_clamp8 (Fnth (make_fixnum (1), b)),
     ie_clamp8 (Fnth (make_fixnum (2), b)), ie_clamp8 (Fnth (make_fixnum (3), b)));
  return Qnil;
}

DEFUN ("cmacs-imgedit-brightness", Fcmacs_imgedit_brightness,
       Scmacs_imgedit_brightness, 2, 2, 0,
       doc: /* Adjust active-layer brightness by AMOUNT (-255..255).  */)
  (Lisp_Object handle, Lisp_Object amount)
{
  cmacs_imgedit_doc_brightness (ie_lookup (handle), ie_int (amount, 0));
  return Qnil;
}

DEFUN ("cmacs-imgedit-contrast", Fcmacs_imgedit_contrast,
       Scmacs_imgedit_contrast, 2, 2, 0,
       doc: /* Adjust active-layer contrast by AMOUNT (-100..100).  */)
  (Lisp_Object handle, Lisp_Object amount)
{
  cmacs_imgedit_doc_contrast (ie_lookup (handle), ie_dbl (amount, 0.0));
  return Qnil;
}

DEFUN ("cmacs-imgedit-invert", Fcmacs_imgedit_invert,
       Scmacs_imgedit_invert, 1, 1, 0,
       doc: /* Invert the active layer's RGB.  */)
  (Lisp_Object handle)
{
  cmacs_imgedit_doc_invert (ie_lookup (handle));
  return Qnil;
}

DEFUN ("cmacs-imgedit-grayscale", Fcmacs_imgedit_grayscale,
       Scmacs_imgedit_grayscale, 1, 1, 0,
       doc: /* Desaturate the active layer to grayscale.  */)
  (Lisp_Object handle)
{
  cmacs_imgedit_doc_grayscale (ie_lookup (handle));
  return Qnil;
}

DEFUN ("cmacs-imgedit-tint", Fcmacs_imgedit_tint, Scmacs_imgedit_tint, 5, 5, 0,
       doc: /* Multiply the active layer by tint colour R G B A.  */)
  (Lisp_Object handle, Lisp_Object r, Lisp_Object g, Lisp_Object b,
   Lisp_Object a)
{
  cmacs_imgedit_doc_tint (ie_lookup (handle), ie_clamp8 (r), ie_clamp8 (g),
                          ie_clamp8 (b), ie_clamp8 (a));
  return Qnil;
}

DEFUN ("cmacs-imgedit-color-replace", Fcmacs_imgedit_color_replace,
       Scmacs_imgedit_color_replace, 3, 3, 0,
       doc: /* Replace exact colour FROM with TO on the active layer.
FROM and TO are (R G B A) lists of bytes 0..255.  */)
  (Lisp_Object handle, Lisp_Object from, Lisp_Object to)
{
  cmacs_imgedit_doc_color_replace
    (ie_lookup (handle),
     ie_clamp8 (Fnth (make_fixnum (0), from)),
     ie_clamp8 (Fnth (make_fixnum (1), from)),
     ie_clamp8 (Fnth (make_fixnum (2), from)),
     ie_clamp8 (Fnth (make_fixnum (3), from)),
     ie_clamp8 (Fnth (make_fixnum (0), to)),
     ie_clamp8 (Fnth (make_fixnum (1), to)),
     ie_clamp8 (Fnth (make_fixnum (2), to)),
     ie_clamp8 (Fnth (make_fixnum (3), to)));
  return Qnil;
}

DEFUN ("cmacs-imgedit-blur", Fcmacs_imgedit_blur, Scmacs_imgedit_blur, 2, 2, 0,
       doc: /* Box-blur the active layer by RADIUS pixels.  */)
  (Lisp_Object handle, Lisp_Object radius)
{
  cmacs_imgedit_doc_blur (ie_lookup (handle), ie_int (radius, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-bloom", Fcmacs_imgedit_bloom, Scmacs_imgedit_bloom,
       1, 4, 0,
       doc: /* Apply bloom to the active layer (THRESHOLD RADIUS INTENSITY).  */)
  (Lisp_Object handle, Lisp_Object threshold, Lisp_Object radius,
   Lisp_Object intensity)
{
  cmacs_imgedit_doc_bloom (ie_lookup (handle), ie_int (threshold, 180),
                           ie_int (radius, 4), ie_dbl (intensity, 0.8));
  return Qnil;
}

DEFUN ("cmacs-imgedit-noise", Fcmacs_imgedit_noise, Scmacs_imgedit_noise,
       1, 4, 0,
       doc: /* Overlay noise on the active layer (AMPLITUDE FREQUENCY SEED).  */)
  (Lisp_Object handle, Lisp_Object amplitude, Lisp_Object frequency,
   Lisp_Object seed)
{
  cmacs_imgedit_doc_noise (ie_lookup (handle), ie_dbl (amplitude, 0.2),
                           ie_dbl (frequency, 1.0),
                           (guint32) ie_int (seed, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-histogram", Fcmacs_imgedit_histogram,
       Scmacs_imgedit_histogram, 1, 2, 0,
       doc: /* Return a 256-element histogram vector for CHANNEL
(0 luma, 1 red, 2 green, 3 blue; default luma).  */)
  (Lisp_Object handle, Lisp_Object channel)
{
  int bins[256];
  Lisp_Object v;
  int i;
  cmacs_imgedit_doc_histogram (ie_lookup (handle), ie_int (channel, 0), bins);
  v = make_vector (256, make_fixnum (0));
  for (i = 0; i < 256; i++)
    ASET (v, i, make_fixnum (bins[i]));
  return v;
}

DEFUN ("cmacs-imgedit-select-rect", Fcmacs_imgedit_select_rect,
       Scmacs_imgedit_select_rect, 5, 5, 0,
       doc: /* Select the rectangle X Y WIDTH HEIGHT.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object w,
   Lisp_Object h)
{
  cmacs_imgedit_doc_select_rect (ie_lookup (handle), ie_int (x, 0),
                                 ie_int (y, 0), ie_int (w, 0), ie_int (h, 0));
  return Qnil;
}

DEFUN ("cmacs-imgedit-select-wand", Fcmacs_imgedit_select_wand,
       Scmacs_imgedit_select_wand, 3, 4, 0,
       doc: /* Magic-wand select from X,Y within TOLERANCE (default 24).  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y, Lisp_Object tolerance)
{
  cmacs_imgedit_doc_select_wand (ie_lookup (handle), ie_int (x, 0),
                                 ie_int (y, 0), ie_int (tolerance, 24));
  return Qnil;
}

DEFUN ("cmacs-imgedit-select-none", Fcmacs_imgedit_select_none,
       Scmacs_imgedit_select_none, 1, 1, 0, doc: /* Clear the selection.  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_select_none (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-select-all", Fcmacs_imgedit_select_all,
       Scmacs_imgedit_select_all, 1, 1, 0, doc: /* Select the whole canvas.  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_select_all (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-select-invert", Fcmacs_imgedit_select_invert,
       Scmacs_imgedit_select_invert, 1, 1, 0, doc: /* Invert the selection.  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_select_invert (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-selection-bbox", Fcmacs_imgedit_selection_bbox,
       Scmacs_imgedit_selection_bbox, 1, 1, 0,
       doc: /* Return the selection bounding box (X Y W H), or nil.  */)
  (Lisp_Object handle)
{
  int x = 0, y = 0, w = 0, h = 0;
  if (!cmacs_imgedit_doc_selection_bbox (ie_lookup (handle), &x, &y, &w, &h))
    return Qnil;
  return list4 (make_fixnum (x), make_fixnum (y), make_fixnum (w),
                make_fixnum (h));
}

DEFUN ("cmacs-imgedit-selection-fill", Fcmacs_imgedit_selection_fill,
       Scmacs_imgedit_selection_fill, 5, 5, 0,
       doc: /* Fill the selection (or whole layer) with R G B A.  */)
  (Lisp_Object handle, Lisp_Object r, Lisp_Object g, Lisp_Object b,
   Lisp_Object a)
{
  cmacs_imgedit_doc_selection_fill (ie_lookup (handle), ie_clamp8 (r),
                                    ie_clamp8 (g), ie_clamp8 (b), ie_clamp8 (a));
  return Qnil;
}

DEFUN ("cmacs-imgedit-selection-crop", Fcmacs_imgedit_selection_crop,
       Scmacs_imgedit_selection_crop, 1, 1, 0,
       doc: /* Crop the document to the selection bounding box.  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_selection_crop (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-export-gif", Fcmacs_imgedit_export_gif,
       Scmacs_imgedit_export_gif, 2, 3, 0,
       doc: /* Export HANDLE's layers as an animated GIF to PATH.
Each layer is one frame at DELAY-CS centiseconds (default 10).  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object delay_cs)
{
  char *err = NULL;
  CHECK_STRING (path);
  if (!cmacs_imgedit_doc_export_gif (ie_lookup (handle), SSDATA (path),
                                     ie_int (delay_cs, 10), &err))
    {
      Lisp_Object m = build_string (err ? err : "GIF export failed");
      g_free (err);
      xsignal1 (Qcmacs_imgedit_error, m);
    }
  return Qt;
}

DEFUN ("cmacs-imgedit-bezier", Fcmacs_imgedit_bezier, Scmacs_imgedit_bezier,
       5, 6, 0,
       doc: /* Draw a cubic Bézier through control points P0 P1 P2 P3.
Each Pn is an (X . Y) cons; optional THICKNESS (default 1).  */)
  (Lisp_Object handle, Lisp_Object p0, Lisp_Object p1, Lisp_Object p2,
   Lisp_Object p3, Lisp_Object thickness)
{
  CHECK_CONS (p0); CHECK_CONS (p1); CHECK_CONS (p2); CHECK_CONS (p3);
  cmacs_imgedit_doc_bezier
    (ie_lookup (handle),
     ie_int (XCAR (p0), 0), ie_int (XCDR (p0), 0),
     ie_int (XCAR (p1), 0), ie_int (XCDR (p1), 0),
     ie_int (XCAR (p2), 0), ie_int (XCDR (p2), 0),
     ie_int (XCAR (p3), 0), ie_int (XCDR (p3), 0), ie_int (thickness, 1));
  return Qnil;
}

DEFUN ("cmacs-imgedit-import-svg", Fcmacs_imgedit_import_svg,
       Scmacs_imgedit_import_svg, 2, 3, 0,
       doc: /* Render SVG file PATH onto the active layer at DPI (default 96).  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object dpi)
{
  char *err = NULL;
  CHECK_STRING (path);
  if (!cmacs_imgedit_doc_import_svg (ie_lookup (handle), SSDATA (path),
                                     ie_dbl (dpi, 96.0), &err))
    {
      Lisp_Object m = build_string (err ? err : "SVG import failed");
      g_free (err);
      xsignal1 (Qcmacs_imgedit_error, m);
    }
  return Qt;
}

DEFUN ("cmacs-imgedit-threshold", Fcmacs_imgedit_threshold,
       Scmacs_imgedit_threshold, 1, 2, 0,
       doc: /* Threshold the active layer to black/white at LEVEL (0..255).  */)
  (Lisp_Object handle, Lisp_Object level)
{
  cmacs_imgedit_doc_threshold (ie_lookup (handle), ie_int (level, 128));
  return Qnil;
}

DEFUN ("cmacs-imgedit-posterize", Fcmacs_imgedit_posterize,
       Scmacs_imgedit_posterize, 1, 2, 0,
       doc: /* Reduce the active layer to LEVELS colours per channel.  */)
  (Lisp_Object handle, Lisp_Object levels)
{
  cmacs_imgedit_doc_posterize (ie_lookup (handle), ie_int (levels, 4));
  return Qnil;
}

DEFUN ("cmacs-imgedit-pixelate", Fcmacs_imgedit_pixelate,
       Scmacs_imgedit_pixelate, 1, 2, 0,
       doc: /* Pixelate the active layer into SIZE-pixel blocks.  */)
  (Lisp_Object handle, Lisp_Object size)
{
  cmacs_imgedit_doc_pixelate (ie_lookup (handle), ie_int (size, 8));
  return Qnil;
}

DEFUN ("cmacs-imgedit-sharpen", Fcmacs_imgedit_sharpen,
       Scmacs_imgedit_sharpen, 1, 1, 0,
       doc: /* Sharpen the active layer (3x3 unsharp kernel).  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_sharpen (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-edge-detect", Fcmacs_imgedit_edge_detect,
       Scmacs_imgedit_edge_detect, 1, 1, 0,
       doc: /* Edge-detect the active layer (3x3 Laplacian).  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_edge_detect (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-emboss", Fcmacs_imgedit_emboss,
       Scmacs_imgedit_emboss, 1, 1, 0,
       doc: /* Emboss the active layer (3x3 emboss kernel).  */)
  (Lisp_Object handle)
{ cmacs_imgedit_doc_emboss (ie_lookup (handle)); return Qnil; }

DEFUN ("cmacs-imgedit-saturation", Fcmacs_imgedit_saturation,
       Scmacs_imgedit_saturation, 2, 2, 0,
       doc: /* Scale active-layer saturation by FACTOR (0 gray, 1 same, >1 vivid).  */)
  (Lisp_Object handle, Lisp_Object factor)
{
  cmacs_imgedit_doc_saturation (ie_lookup (handle), ie_dbl (factor, 1.0));
  return Qnil;
}

DEFUN ("cmacs-imgedit-pixel-at", Fcmacs_imgedit_pixel_at,
       Scmacs_imgedit_pixel_at, 3, 3, 0,
       doc: /* Return the flattened pixel at X,Y as (R G B A), or nil.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y)
{
  guint8 r = 0, g = 0, b = 0, a = 0;

  if (!cmacs_imgedit_doc_get_pixel (ie_lookup (handle), ie_int (x, -1),
                                    ie_int (y, -1), &r, &g, &b, &a))
    return Qnil;
  return list4 (make_fixnum (r), make_fixnum (g), make_fixnum (b),
                make_fixnum (a));
}

DEFUN ("cmacs-imgedit-push-undo", Fcmacs_imgedit_push_undo,
       Scmacs_imgedit_push_undo, 1, 1, 0,
       doc: /* Snapshot the active layer for undo before an edit.  */)
  (Lisp_Object handle)
{
  cmacs_imgedit_doc_push_undo (ie_lookup (handle));
  return Qnil;
}

DEFUN ("cmacs-imgedit-undo", Fcmacs_imgedit_undo, Scmacs_imgedit_undo, 1, 1, 0,
       doc: /* Undo the last edit.  Return non-nil if something was undone.  */)
  (Lisp_Object handle)
{
  return cmacs_imgedit_doc_undo (ie_lookup (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-redo", Fcmacs_imgedit_redo, Scmacs_imgedit_redo, 1, 1, 0,
       doc: /* Redo the last undone edit.  Return non-nil if redone.  */)
  (Lisp_Object handle)
{
  return cmacs_imgedit_doc_redo (ie_lookup (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-can-undo-p", Fcmacs_imgedit_can_undo_p,
       Scmacs_imgedit_can_undo_p, 1, 1, 0, doc: /* Non-nil if undo available.  */)
  (Lisp_Object handle)
{
  return cmacs_imgedit_doc_can_undo (ie_lookup (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-imgedit-can-redo-p", Fcmacs_imgedit_can_redo_p,
       Scmacs_imgedit_can_redo_p, 1, 1, 0, doc: /* Non-nil if redo available.  */)
  (Lisp_Object handle)
{
  return cmacs_imgedit_doc_can_redo (ie_lookup (handle)) ? Qt : Qnil;
}

void
syms_of_cmacs_imgedit_defuns (void)
{
  DEFSYM (Qcmacs_imgedit_error, "cmacs-imgedit-error");
  Fput (Qcmacs_imgedit_error, Qerror_conditions,
        list2 (Qcmacs_imgedit_error, Qerror));
  Fput (Qcmacs_imgedit_error, Qerror_message,
        build_string ("CMacs image-editor error"));

  defsubr (&Scmacs_imgedit_supported_p);
  defsubr (&Scmacs_imgedit_new);
  defsubr (&Scmacs_imgedit_open);
  defsubr (&Scmacs_imgedit_free);
  defsubr (&Scmacs_imgedit_width);
  defsubr (&Scmacs_imgedit_height);
  defsubr (&Scmacs_imgedit_save);
  defsubr (&Scmacs_imgedit_export_png_bytes);
  defsubr (&Scmacs_imgedit_n_layers);
  defsubr (&Scmacs_imgedit_add_layer);
  defsubr (&Scmacs_imgedit_add_layer_from_file);
  defsubr (&Scmacs_imgedit_add_layer_rgba);
  defsubr (&Scmacs_imgedit_remove_layer);
  defsubr (&Scmacs_imgedit_move_layer);
  defsubr (&Scmacs_imgedit_duplicate_layer);
  defsubr (&Scmacs_imgedit_active_layer);
  defsubr (&Scmacs_imgedit_set_active_layer);
  defsubr (&Scmacs_imgedit_layer_name);
  defsubr (&Scmacs_imgedit_set_layer_name);
  defsubr (&Scmacs_imgedit_layer_opacity);
  defsubr (&Scmacs_imgedit_set_layer_opacity);
  defsubr (&Scmacs_imgedit_layer_blend);
  defsubr (&Scmacs_imgedit_set_layer_blend);
  defsubr (&Scmacs_imgedit_layer_visible_p);
  defsubr (&Scmacs_imgedit_set_layer_visible);
  defsubr (&Scmacs_imgedit_layer_locked_p);
  defsubr (&Scmacs_imgedit_set_layer_locked);
  defsubr (&Scmacs_imgedit_set_layer_offset);
  defsubr (&Scmacs_imgedit_set_draw_blend);
  defsubr (&Scmacs_imgedit_set_color);
  defsubr (&Scmacs_imgedit_fill);
  defsubr (&Scmacs_imgedit_set_pixel);
  defsubr (&Scmacs_imgedit_draw_line);
  defsubr (&Scmacs_imgedit_draw_rect);
  defsubr (&Scmacs_imgedit_draw_circle);
  defsubr (&Scmacs_imgedit_draw_arrow);
  defsubr (&Scmacs_imgedit_draw_ellipse);
  defsubr (&Scmacs_imgedit_draw_text);
  defsubr (&Scmacs_imgedit_flood_fill);
  defsubr (&Scmacs_imgedit_flip);
  defsubr (&Scmacs_imgedit_resize);
  defsubr (&Scmacs_imgedit_crop);
  defsubr (&Scmacs_imgedit_rotate);
  defsubr (&Scmacs_imgedit_gradient);
  defsubr (&Scmacs_imgedit_brightness);
  defsubr (&Scmacs_imgedit_contrast);
  defsubr (&Scmacs_imgedit_invert);
  defsubr (&Scmacs_imgedit_grayscale);
  defsubr (&Scmacs_imgedit_tint);
  defsubr (&Scmacs_imgedit_color_replace);
  defsubr (&Scmacs_imgedit_blur);
  defsubr (&Scmacs_imgedit_bloom);
  defsubr (&Scmacs_imgedit_noise);
  defsubr (&Scmacs_imgedit_histogram);
  defsubr (&Scmacs_imgedit_select_rect);
  defsubr (&Scmacs_imgedit_select_wand);
  defsubr (&Scmacs_imgedit_select_none);
  defsubr (&Scmacs_imgedit_select_all);
  defsubr (&Scmacs_imgedit_select_invert);
  defsubr (&Scmacs_imgedit_selection_bbox);
  defsubr (&Scmacs_imgedit_selection_fill);
  defsubr (&Scmacs_imgedit_selection_crop);
  defsubr (&Scmacs_imgedit_export_gif);
  defsubr (&Scmacs_imgedit_bezier);
  defsubr (&Scmacs_imgedit_import_svg);
  defsubr (&Scmacs_imgedit_threshold);
  defsubr (&Scmacs_imgedit_posterize);
  defsubr (&Scmacs_imgedit_pixelate);
  defsubr (&Scmacs_imgedit_sharpen);
  defsubr (&Scmacs_imgedit_edge_detect);
  defsubr (&Scmacs_imgedit_emboss);
  defsubr (&Scmacs_imgedit_saturation);
  defsubr (&Scmacs_imgedit_viewport_bind);
  defsubr (&Scmacs_imgedit_clipboard_available_p);
  defsubr (&Scmacs_imgedit_clipboard_set_png);
  defsubr (&Scmacs_imgedit_clipboard_get_png);
  defsubr (&Scmacs_imgedit_pixel_at);
  defsubr (&Scmacs_imgedit_push_undo);
  defsubr (&Scmacs_imgedit_undo);
  defsubr (&Scmacs_imgedit_redo);
  defsubr (&Scmacs_imgedit_can_undo_p);
  defsubr (&Scmacs_imgedit_can_redo_p);
}

#endif /* HAVE_CMACS_IMGEDIT */
