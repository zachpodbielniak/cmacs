/* cmacs-libregnum-defuns.c --- Elisp entry points.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-scenes.h"
#include "../gobject/cmacs-gobject.h"   /* cmacs_gobject_wrap for the inspector */

/* lrg-script-binding.h is GLib-only (no raylib/Color conflict) so it is
 * safe to include here alongside lisp.h.  We define LIBREGNUM_COMPILATION
 * to satisfy the "only include via libregnum.h" guard in that header.
 * Define LRG_BUILD_EDITOR to get the symbols (it is always set in our
 * build since liblibregnum.a is built with BUILD_EDITOR=1). */
#ifndef LRG_BUILD_EDITOR
#define LRG_BUILD_EDITOR 1
#endif
#ifndef LIBREGNUM_COMPILATION
#define LIBREGNUM_COMPILATION
#endif
#include "editor/lrg-script-binding.h"
#undef LIBREGNUM_COMPILATION

#include <math.h>

/* Defined further down, but needed by DEFUNs that appear before it. */
static double cmacs_libregnum__to_double (Lisp_Object obj);

DEFUN ("cmacs-libregnum-supported-p", Fcmacs_libregnum_supported_p,
       Scmacs_libregnum_supported_p, 0, 0, 0,
       doc: /* Return t when cmacs-libregnum is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-libregnum-attach", Fcmacs_libregnum_attach,
       Scmacs_libregnum_attach, 1, 3, 0,
       doc: /* Attach a libregnum view to BUFFER.
WIDTH and HEIGHT default to 800x500.  Returns t on success or signals
`cmacs-libregnum-error' on failure (e.g. GL context unavailable).
Idempotent: re-attaching the same buffer is a no-op.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CHECK_BUFFER (buffer);
  int w = NILP (width)  ? 800 : (CHECK_FIXNAT (width),  XFIXNUM (width));
  int h = NILP (height) ? 500 : (CHECK_FIXNAT (height), XFIXNUM (height));
  if (cmacs_libregnum_view_for_buffer (buffer))
    return Qt;
  cmacs_libregnum_view_new (buffer, w, h);
  return Qt;
}

DEFUN ("cmacs-libregnum-detach", Fcmacs_libregnum_detach,
       Scmacs_libregnum_detach, 1, 1, 0,
       doc: /* Detach and destroy the libregnum view bound to BUFFER.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_destroy (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-attached-p", Fcmacs_libregnum_attached_p,
       Scmacs_libregnum_attached_p, 1, 1, 0,
       doc: /* Return t if BUFFER has an attached libregnum view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  return cmacs_libregnum_view_for_buffer (buffer) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-resize", Fcmacs_libregnum_resize,
       Scmacs_libregnum_resize, 3, 3, 0,
       doc: /* Resize BUFFER's libregnum view to WIDTH x HEIGHT.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  cmacs_libregnum_view_resize (v, XFIXNUM (width), XFIXNUM (height));
  return Qt;
}

DEFUN ("cmacs-libregnum-view-size", Fcmacs_libregnum_view_size,
       Scmacs_libregnum_view_size, 1, 1, 0,
       doc: /* Return BUFFER's libregnum view (FBO) size as a list (W H), or
nil.  Used to map window-relative drop coordinates into view-local pixels.  */)
  (Lisp_Object buffer)
{
  int w = 0, h = 0;
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_view_get_size (v, &w, &h);
  return list2 (make_fixnum (w), make_fixnum (h));
}

DEFUN ("cmacs-libregnum-redraw", Fcmacs_libregnum_redraw,
       Scmacs_libregnum_redraw, 1, 1, 0,
       doc: /* Request a redraw of BUFFER's libregnum view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-set-animated", Fcmacs_libregnum_set_animated,
       Scmacs_libregnum_set_animated, 2, 3, 0,
       doc: /* Enable or disable continuous animation for BUFFER's view.
When FLAG is non-nil, a shared frame timer re-renders the view at
TARGET-FPS (default 60) for as long as the buffer stays on-screen; the
timer pauses automatically when the buffer is hidden and stops entirely
when no animated view remains.  When FLAG is nil, the view reverts to
rendering only on demand (input, camera changes, explicit redraw).  */)
  (Lisp_Object buffer, Lisp_Object flag, Lisp_Object target_fps)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  int fps = 0;
  if (!NILP (target_fps))
    {
      CHECK_FIXNAT (target_fps);
      fps = XFIXNUM (target_fps);
    }
  cmacs_libregnum_view_set_animated (v, !NILP (flag), fps);
  return NILP (flag) ? Qnil : Qt;
}

DEFUN ("cmacs-libregnum-animated-p", Fcmacs_libregnum_animated_p,
       Scmacs_libregnum_animated_p, 1, 1, 0,
       doc: /* Return t if BUFFER's libregnum view is in animation mode.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  return (v && cmacs_libregnum_view_get_animated (v)) ? Qt : Qnil;
}

/* ── 2D image-display mode DEFUNs (imgedit / vidstudio live viewport) ────
 * Each resolves BUFFER -> view -> render ctx and drives the image_* API; a
 * redraw is requested after any state change.  These never touch the GPU
 * (the ctx setters defer the upload to frame top). */

/* Resolve BUFFER to its render ctx, or NULL.  */
static CmacsLibregnumRenderCtx *
cmacs_libregnum_image_ctx (Lisp_Object buffer)
{
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  return v ? cmacs_libregnum_view_get_render_ctx (v) : NULL;
}

DEFUN ("cmacs-libregnum-image-enter", Fcmacs_libregnum_image_enter,
       Scmacs_libregnum_image_enter, 1, 2, 0,
       doc: /* Put BUFFER's view into 2D image-display mode (ON nil exits).  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx) cmacs_libregnum_render_ctx_image_enter (ctx, NILP (on) ? FALSE : TRUE);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return ctx ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-image-p", Fcmacs_libregnum_image_p,
       Scmacs_libregnum_image_p, 1, 1, 0,
       doc: /* Return t if BUFFER's view is in 2D image-display mode.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  return (ctx && cmacs_libregnum_render_ctx_is_image (ctx)) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-image-upload-rgba", Fcmacs_libregnum_image_upload_rgba,
       Scmacs_libregnum_image_upload_rgba, 4, 4, 0,
       doc: /* Upload a raw RGBA8 image (W x H, unibyte RGBA string) to BUFFER.  */)
  (Lisp_Object buffer, Lisp_Object w, Lisp_Object h, Lisp_Object rgba)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNAT (w); CHECK_FIXNAT (h); CHECK_STRING (rgba);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    cmacs_libregnum_render_ctx_image_upload_rgba
      (ctx, XFIXNUM (w), XFIXNUM (h),
       (const guint8 *) SDATA (rgba), SBYTES (rgba));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-refresh", Fcmacs_libregnum_image_refresh,
       Scmacs_libregnum_image_refresh, 1, 5, 0,
       doc: /* Re-upload BUFFER's bound image (optional dirty rect X Y W H).  */)
  (Lisp_Object buffer, Lisp_Object x, Lisp_Object y, Lisp_Object w,
   Lisp_Object h)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    {
      if (NILP (x))
        cmacs_libregnum_render_ctx_image_refresh (ctx);
      else
        cmacs_libregnum_render_ctx_image_refresh_rect
          (ctx, XFIXNUM (x), XFIXNUM (y), XFIXNUM (w), XFIXNUM (h));
    }
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-set-view", Fcmacs_libregnum_image_set_view,
       Scmacs_libregnum_image_set_view, 4, 4, 0,
       doc: /* Set BUFFER image view SCALE and pan PAN-X PAN-Y (FBO px).  */)
  (Lisp_Object buffer, Lisp_Object scale, Lisp_Object px, Lisp_Object py)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    cmacs_libregnum_render_ctx_image_set_view
      (ctx, XFLOATINT (scale), XFLOATINT (px), XFLOATINT (py));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-view", Fcmacs_libregnum_image_view,
       Scmacs_libregnum_image_view, 1, 1, 0,
       doc: /* Return BUFFER image view as (SCALE PAN-X PAN-Y), or nil.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  double s = 0, px = 0, py = 0;
  if (!ctx) return Qnil;
  cmacs_libregnum_render_ctx_image_get_view (ctx, &s, &px, &py);
  return list3 (make_float (s), make_float (px), make_float (py));
}

DEFUN ("cmacs-libregnum-image-zoom-at", Fcmacs_libregnum_image_zoom_at,
       Scmacs_libregnum_image_zoom_at, 4, 4, 0,
       doc: /* Zoom BUFFER image by FACTOR about view pixel (VX VY).  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy, Lisp_Object factor)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    cmacs_libregnum_render_ctx_image_zoom_at
      (ctx, XFLOATINT (vx), XFLOATINT (vy), XFLOATINT (factor));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-fit", Fcmacs_libregnum_image_fit,
       Scmacs_libregnum_image_fit, 1, 1, 0,
       doc: /* Fit BUFFER's image to its view size, centred.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  CmacsLibregnumRenderCtx *ctx = v ? cmacs_libregnum_view_get_render_ctx (v)
                                   : NULL;
  if (ctx && v)
    {
      int vw = 0, vh = 0;
      cmacs_libregnum_view_get_size (v, &vw, &vh);
      cmacs_libregnum_render_ctx_image_fit (ctx, vw, vh);
      cmacs_libregnum_view_request_redraw (v);
    }
  return Qt;
}

DEFUN ("cmacs-libregnum-image-view-to-doc", Fcmacs_libregnum_image_view_to_doc,
       Scmacs_libregnum_image_view_to_doc, 3, 3, 0,
       doc: /* Map BUFFER view pixel (VX VY) to a doc pixel (DX . DY), or nil
if outside the document.  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  int dx = 0, dy = 0;
  if (!ctx) return Qnil;
  return cmacs_libregnum_render_ctx_image_view_to_doc
           (ctx, XFLOATINT (vx), XFLOATINT (vy), &dx, &dy)
         ? Fcons (make_fixnum (dx), make_fixnum (dy)) : Qnil;
}

DEFUN ("cmacs-libregnum-image-set-checker", Fcmacs_libregnum_image_set_checker,
       Scmacs_libregnum_image_set_checker, 2, 2, 0,
       doc: /* Show/hide BUFFER image transparency checkerboard.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx) cmacs_libregnum_render_ctx_image_set_checker (ctx, !NILP (on));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-set-grid", Fcmacs_libregnum_image_set_grid,
       Scmacs_libregnum_image_set_grid, 2, 2, 0,
       doc: /* Show/hide BUFFER image pixel grid (visible at high zoom).  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx) cmacs_libregnum_render_ctx_image_set_grid (ctx, !NILP (on));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-set-cursor", Fcmacs_libregnum_image_set_cursor,
       Scmacs_libregnum_image_set_cursor, 4, 4, 0,
       doc: /* Set BUFFER brush-cursor overlay at doc (DX DY), RADIUS px
(DX < 0 hides it).  */)
  (Lisp_Object buffer, Lisp_Object dx, Lisp_Object dy, Lisp_Object radius)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    cmacs_libregnum_render_ctx_image_set_cursor
      (ctx, XFLOATINT (dx), XFLOATINT (dy), XFLOATINT (radius));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-set-marquee", Fcmacs_libregnum_image_set_marquee,
       Scmacs_libregnum_image_set_marquee, 2, 6, 0,
       doc: /* Set BUFFER selection marquee ON at doc rect (X Y W H).  */)
  (Lisp_Object buffer, Lisp_Object on, Lisp_Object x, Lisp_Object y,
   Lisp_Object w, Lisp_Object h)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    cmacs_libregnum_render_ctx_image_set_marquee
      (ctx, !NILP (on), NILP (x) ? 0 : XFIXNUM (x), NILP (y) ? 0 : XFIXNUM (y),
       NILP (w) ? 0 : XFIXNUM (w), NILP (h) ? 0 : XFIXNUM (h));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-image-set-label-font",
       Fcmacs_libregnum_image_set_label_font,
       Scmacs_libregnum_image_set_label_font, 2, 2, 0,
       doc: /* Set BUFFER's timeline-strip clip-id label font to the TTF/OTF at
PATH (nil/"" restores the built-in default).  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CmacsLibregnumRenderCtx *ctx;
  CHECK_BUFFER (buffer);
  ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    cmacs_libregnum_render_ctx_image_set_label_font
      (ctx, STRINGP (path) ? SSDATA (path) : NULL);
  return Qnil;
}

DEFUN ("cmacs-libregnum-image-timeline-hit",
       Fcmacs_libregnum_image_timeline_hit,
       Scmacs_libregnum_image_timeline_hit, 5, 5, 0,
       doc: /* Hit-test BUFFER's timeline strip at view point VX VY in a VW x VH
view.  Returns (FRAME CLIP-ID NEAR-EDGE) when inside the strip, else nil.  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy, Lisp_Object vw,
   Lisp_Object vh)
{
  CmacsLibregnumRenderCtx *ctx;
  int frame = 0, cid = -1;
  gboolean edge = FALSE;
  CHECK_BUFFER (buffer);
  ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx == NULL
      || !cmacs_libregnum_render_ctx_image_timeline_hit
            (ctx, XFLOATINT (vx), XFLOATINT (vy),
             (int) XFIXNUM (vw), (int) XFIXNUM (vh), &frame, &cid, &edge))
    return Qnil;
  return list3 (make_fixnum (frame), make_fixnum (cid),
                edge ? Qt : Qnil);
}

DEFUN ("cmacs-libregnum-image-timeline", Fcmacs_libregnum_image_timeline,
       Scmacs_libregnum_image_timeline, 4, 4, 0,
       doc: /* Set BUFFER's viewport timeline strip.
PLAYHEAD frame, TOTAL frames, and CLIPS = a list of (TRACK START DUR R G B).
The number of tracks is inferred from the clips.  */)
  (Lisp_Object buffer, Lisp_Object playhead, Lisp_Object total,
   Lisp_Object clips)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx)
    {
      int ntr = 1;
      Lisp_Object l;
      cmacs_libregnum_render_ctx_image_timeline_clear (ctx);
      for (l = clips; CONSP (l); l = XCDR (l))
        {
          Lisp_Object c = XCAR (l);
          int cid = NILP (Fnth (make_fixnum (0), c)) ? -1
                    : XFIXNUM (Fnth (make_fixnum (0), c));
          int ctrk = NILP (Fnth (make_fixnum (1), c)) ? 0
                     : XFIXNUM (Fnth (make_fixnum (1), c));
          cmacs_libregnum_render_ctx_image_timeline_add_clip
            (ctx, cid, ctrk,
             XFIXNUM (Fnth (make_fixnum (2), c)),
             XFIXNUM (Fnth (make_fixnum (3), c)),
             (unsigned char) XFIXNUM (Fnth (make_fixnum (4), c)),
             (unsigned char) XFIXNUM (Fnth (make_fixnum (5), c)),
             (unsigned char) XFIXNUM (Fnth (make_fixnum (6), c)));
          if (ctrk + 1 > ntr) ntr = ctrk + 1;
        }
      cmacs_libregnum_render_ctx_image_timeline_set
        (ctx, NILP (playhead) ? 0 : XFIXNUM (playhead),
         NILP (total) ? 0 : XFIXNUM (total), ntr);
    }
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-build-tree", Fcmacs_libregnum_build_tree,
       Scmacs_libregnum_build_tree, 2, 2, 0,
       doc: /* Build the project-tree scene for BUFFER under ROOT.
ROOT is the absolute path of a directory.  Walks up to ~1500 regular
files (skipping .git, build, node_modules, native-lisp), placing each
on a 3D grid sized by file size and coloured by extension.  */)
  (Lisp_Object buffer, Lisp_Object root)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (root);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  Lisp_Object encoded = ENCODE_FILE (root);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_scene_tree_build (ctx, SSDATA (encoded)))
    error ("cmacs-libregnum: project-tree build failed");
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-build-gobject", Fcmacs_libregnum_build_gobject,
       Scmacs_libregnum_build_gobject, 1, 2, 0,
       doc: /* Build the GObject hierarchy scene for BUFFER.
Optional NAMESPACE is a leading type-name prefix to filter on
(e.g. "Gtk", "Lrg", "Mcp").  When nil or "", emits all descendants of
GObject up to the internal cap (~1500 nodes).  */)
  (Lisp_Object buffer, Lisp_Object namespace)
{
  CHECK_BUFFER (buffer);
  const char *ns = NULL;
  if (!NILP (namespace))
    {
      CHECK_STRING (namespace);
      ns = SSDATA (namespace);
    }
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_scene_gobject_build (ctx, ns))
    error ("cmacs-libregnum: gobject scene build failed");
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-build-mindmap", Fcmacs_libregnum_build_mindmap,
       Scmacs_libregnum_build_mindmap, 2, 2, 0,
       doc: /* Build the org-mindmap scene for BUFFER from ORG-FILE.
ORG-FILE is the absolute path of a `.org' file.  Each heading
becomes a node; parent/child links become edges.  Layout is
deterministic radial-cone.  */)
  (Lisp_Object buffer, Lisp_Object org_file)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (org_file);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  Lisp_Object encoded = ENCODE_FILE (org_file);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_scene_mindmap_build (ctx, SSDATA (encoded)))
    error ("cmacs-libregnum: mindmap scene build failed");
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-tree-nodes", Fcmacs_libregnum_tree_nodes,
       Scmacs_libregnum_tree_nodes, 1, 1, 0,
       doc: /* Return BUFFER's scene node model as a vector.
Element I (the node id) is a plist
  (:id I :name NAME :path PATH :dir DIR :depth DEPTH :parent PARENT)
where DIR is t for directories, PARENT is the parent node's id or nil
for the root.  Returns nil if BUFFER has no attached view or no scene.
Used by the navigation layer; rebuild the scene to refresh it.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  guint n = cmacs_libregnum_render_ctx_node_count (ctx);
  if (n == 0) return Qnil;
  Lisp_Object vec = make_nil_vector (n);
  for (guint i = 0; i < n; i++)
    {
      const char *path = NULL, *name = NULL;
      gboolean is_dir = FALSE;
      int depth = 0, parent = -1;
      if (!cmacs_libregnum_render_ctx_node_info (ctx, i, &path, &name,
                                                 &is_dir, &depth, &parent))
        continue;
      Lisp_Object lpath = DECODE_FILE (build_unibyte_string (path ? path : ""));
      Lisp_Object lname = DECODE_FILE (build_unibyte_string (name ? name : ""));
      Lisp_Object pl =
        CALLN (Flist,
               intern (":id"),     make_fixnum (i),
               intern (":name"),   lname,
               intern (":path"),   lpath,
               intern (":dir"),    is_dir ? Qt : Qnil,
               intern (":depth"),  make_fixnum (depth),
               intern (":parent"), parent >= 0 ? make_fixnum (parent) : Qnil);
      ASET (vec, i, pl);
    }
  return vec;
}

DEFUN ("cmacs-libregnum-set-selection", Fcmacs_libregnum_set_selection,
       Scmacs_libregnum_set_selection, 2, 3, 0,
       doc: /* Select node ID in BUFFER's scene (nil clears selection).
The selected node gets a highlight box.  With non-nil FOCUS, the camera
also eases to frame it.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object focus)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gint i = -1;
  if (!NILP (id))
    {
      CHECK_FIXNAT (id);
      i = XFIXNUM (id);
    }
  cmacs_libregnum_render_ctx_set_selected (ctx, i);
  if (!NILP (focus) && i >= 0)
    cmacs_libregnum_render_ctx_focus_node (ctx, i);
  cmacs_libregnum_view_request_redraw (v);
  return id;
}

DEFUN ("cmacs-libregnum-set-node-label-mode",
       Fcmacs_libregnum_set_node_label_mode,
       Scmacs_libregnum_set_node_label_mode, 3, 3, 0,
       doc: /* Set the label policy for node ID in BUFFER's scene.
MODE is one of the symbols `never', `selected', `hover', `always', or
nil for the legacy default (label directories plus the selection).  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object mode)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNAT (id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  int m = CMACS_LIBREGNUM_LABEL_LEGACY;

  if (EQ (mode, Qcmacs_label_never))         m = CMACS_LIBREGNUM_LABEL_NEVER;
  else if (EQ (mode, Qcmacs_label_selected)) m = CMACS_LIBREGNUM_LABEL_SELECTED;
  else if (EQ (mode, Qcmacs_label_hover))    m = CMACS_LIBREGNUM_LABEL_HOVER;
  else if (EQ (mode, Qcmacs_label_always))   m = CMACS_LIBREGNUM_LABEL_ALWAYS;

  cmacs_libregnum_render_ctx_set_node_label_mode (ctx, XFIXNUM (id), m);
  cmacs_libregnum_view_request_redraw (v);
  return mode;
}

DEFUN ("cmacs-libregnum-set-inscene-labels",
       Fcmacs_libregnum_set_inscene_labels,
       Scmacs_libregnum_set_inscene_labels, 2, 2, 0,
       doc: /* Draw BUFFER's node labels inside the scene when ON is non-nil.

By default labels are painted in cairo over the blitted framebuffer,
which happens only under pgtk -- so they do not exist under `emacs
--lrg', and never show up in `cmacs-libregnum-snapshot'.  With ON, they
are drawn into the framebuffer itself, which both display backends
share, and the cairo pass suppresses itself so nothing is drawn
twice.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_inscene_labels
    (cmacs_libregnum_view_get_render_ctx (v), !NILP (on));
  cmacs_libregnum_view_request_redraw (v);
  return on;
}

DEFUN ("cmacs-libregnum-set-label-font", Fcmacs_libregnum_set_label_font,
       Scmacs_libregnum_set_label_font, 2, 3, 0,
       doc: /* Use the TrueType font at PATH for BUFFER's in-scene labels.
BASE-PX is the atlas baking size (default 32); text is drawn smaller and
filtered down, which is what makes it legible.  A nil or unloadable PATH
falls back to the built-in bitmap font.  */)
  (Lisp_Object buffer, Lisp_Object path, Lisp_Object base_px)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  Lisp_Object enc = NILP (path) ? Qnil : ENCODE_FILE (Fexpand_file_name (path, Qnil));
  cmacs_libregnum_render_ctx_set_label_font
    (cmacs_libregnum_view_get_render_ctx (v),
     NILP (enc) ? NULL : SSDATA (enc),
     FIXNUMP (base_px) ? (int) XFIXNUM (base_px) : 32);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-set-label-style", Fcmacs_libregnum_set_label_style,
       Scmacs_libregnum_set_label_style, 1, 5, 0,
       doc: /* Configure BUFFER's in-scene label appearance.
PX is the text height in pixels, SHADOW draws a drop shadow, DECLUTTER
drops labels that would overlap one already placed (the selection and
the hovered node are never dropped), and MAX-LABELS caps how many are
drawn per frame.  */)
  (Lisp_Object buffer, Lisp_Object px, Lisp_Object shadow,
   Lisp_Object declutter, Lisp_Object max_labels)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_label_style
    (cmacs_libregnum_view_get_render_ctx (v),
     FIXNUMP (px) ? (int) XFIXNUM (px) : 0,
     !NILP (shadow), !NILP (declutter),
     FIXNUMP (max_labels) ? (int) XFIXNUM (max_labels) : 0);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-nearest-in-direction",
       Fcmacs_libregnum_nearest_in_direction,
       Scmacs_libregnum_nearest_in_direction, 4, 6, 0,
       doc: /* Return the node nearest FROM in screen direction (DX . DY).

DX and DY are a screen-space direction with y growing downward; they
need not be normalised.  CONE-DEGREES is the half-angle of the search
cone (default 45).  VISIBLE-ONLY, when non-nil, ignores nodes the scene
considers hidden.  Returns a node id, or nil when nothing qualifies.

This is what makes h/j/k/l mean \"the node over there\" on a graph that
has no rows or columns.  */)
  (Lisp_Object buffer, Lisp_Object from, Lisp_Object dx, Lisp_Object dy,
   Lisp_Object cone_degrees, Lisp_Object visible_only)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (from);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;

  int vw = 0, vh = 0;
  cmacs_libregnum_view_get_size (v, &vw, &vh);

  double deg = FIXNUMP (cone_degrees) ? (double) XFIXNUM (cone_degrees)
               : FLOATP (cone_degrees) ? XFLOAT_DATA (cone_degrees)
               : 45.0;
  if (deg <= 0.0) deg = 45.0;
  if (deg >= 89.0) deg = 89.0;

  gint hit = cmacs_libregnum_render_ctx_nearest_in_direction
    (cmacs_libregnum_view_get_render_ctx (v), (gint) XFIXNUM (from),
     cmacs_libregnum__to_double (dx), cmacs_libregnum__to_double (dy),
     vw, vh, cos (deg * M_PI / 180.0), !NILP (visible_only));
  return (hit < 0) ? Qnil : make_fixnum (hit);
}

DEFUN ("cmacs-libregnum-node-onscreen-p", Fcmacs_libregnum_node_onscreen_p,
       Scmacs_libregnum_node_onscreen_p, 2, 3, 0,
       doc: /* Return non-nil if node ID is inside BUFFER's viewport.
MARGIN insets the test rectangle, so a node hugging the edge counts as
off-screen.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object margin)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;

  int vw = 0, vh = 0;
  cmacs_libregnum_view_get_size (v, &vw, &vh);
  return cmacs_libregnum_render_ctx_node_onscreen_p
           (cmacs_libregnum_view_get_render_ctx (v), (gint) XFIXNUM (id),
            vw, vh,
            FIXNUMP (margin) ? (double) XFIXNUM (margin) : 0.0)
         ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-set-match-set", Fcmacs_libregnum_set_match_set,
       Scmacs_libregnum_set_match_set, 2, 3, 0,
       doc: /* Mark node IDS in BUFFER as search matches.

IDS is a vector or list of node ids; nil clears the set.  With non-nil
DIM-REST, every other node is de-emphasised, which is what makes a
handful of matches readable on a crowded graph.

One call replaces the whole set, so an incremental search costs one
call per keystroke rather than one per node.  */)
  (Lisp_Object buffer, Lisp_Object ids, Lisp_Object dim_rest)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;

  Lisp_Object vec = NILP (ids) ? Qnil
                    : (VECTORP (ids) ? ids : Fvconcat (1, &ids));
  ptrdiff_t n = NILP (vec) ? 0 : ASIZE (vec);
  gint *buf = (n > 0) ? xnmalloc (n, sizeof *buf) : NULL;
  ptrdiff_t i, k = 0;

  for (i = 0; i < n; i++)
    {
      Lisp_Object e = AREF (vec, i);
      if (FIXNUMP (e)) buf[k++] = (gint) XFIXNUM (e);
    }
  cmacs_libregnum_render_ctx_set_match_set
    (cmacs_libregnum_view_get_render_ctx (v), buf, (gsize) k,
     !NILP (dim_rest));
  xfree (buf);
  cmacs_libregnum_view_request_redraw (v);
  return make_fixnum (k);
}

DEFUN ("cmacs-libregnum-set-node-flags", Fcmacs_libregnum_set_node_flags,
       Scmacs_libregnum_set_node_flags, 3, 3, 0,
       doc: /* Set node ID's flag bitmask in BUFFER to FLAGS.
Bit 0 is a search match, bit 1 de-emphasised, bit 2 pinned, bit 3 a
neighbour of the selection.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object flags)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (id);
  CHECK_FIXNUM (flags);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_node_flags
    (cmacs_libregnum_view_get_render_ctx (v), (gint) XFIXNUM (id),
     (guint) XFIXNUM (flags));
  return flags;
}

DEFUN ("cmacs-libregnum-clear-node-flags", Fcmacs_libregnum_clear_node_flags,
       Scmacs_libregnum_clear_node_flags, 2, 2, 0,
       doc: /* Clear the bits in MASK on every node of BUFFER.  */)
  (Lisp_Object buffer, Lisp_Object mask)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (mask);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_clear_node_flags
    (cmacs_libregnum_view_get_render_ctx (v), (guint) XFIXNUM (mask));
  return Qt;
}

DEFUN ("cmacs-libregnum-node-flags", Fcmacs_libregnum_node_flags,
       Scmacs_libregnum_node_flags, 2, 2, 0,
       doc: /* Return the flag bitmask of node ID in BUFFER.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  return make_fixnum
    (cmacs_libregnum_render_ctx_get_node_flags
       (cmacs_libregnum_view_get_render_ctx (v), (gint) XFIXNUM (id)));
}

DEFUN ("cmacs-libregnum-set-label-decor", Fcmacs_libregnum_set_label_decor,
       Scmacs_libregnum_set_label_decor, 1, 3, 0,
       doc: /* Decorate BUFFER's in-scene labels.
With non-nil BACKDROP each label gets a translucent plate behind it, so
the scene's own geometry does not run through the text.  With non-nil
RINGS the selected, hovered and matched nodes get screen-space emphasis
rings, which read the same at any zoom level.  */)
  (Lisp_Object buffer, Lisp_Object backdrop, Lisp_Object rings)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_label_decor
    (cmacs_libregnum_view_get_render_ctx (v), !NILP (backdrop), !NILP (rings));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-set-selection-style",
       Fcmacs_libregnum_set_selection_style,
       Scmacs_libregnum_set_selection_style, 2, 2, 0,
       doc: /* Set how BUFFER marks its selected node.
STYLE is `box' (a wireframe cube, the default, right for scenes whose
nodes are boxes), `halo' (a wireframe shell, right for spheres), or
`none' for a scene that draws its own marker.  */)
  (Lisp_Object buffer, Lisp_Object style)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  int st = CMACS_LIBREGNUM_SELECTION_BOX;
  if (EQ (style, Qcmacs_sel_halo))      st = CMACS_LIBREGNUM_SELECTION_HALO;
  else if (EQ (style, Qnone))           st = CMACS_LIBREGNUM_SELECTION_NONE;
  cmacs_libregnum_render_ctx_set_selection_style
    (cmacs_libregnum_view_get_render_ctx (v), st);
  cmacs_libregnum_view_request_redraw (v);
  return style;
}

/* 0xRRGGBBAA from a Lisp integer, clamped. */
static guint32
cmacs_lrg_rgba (Lisp_Object v, guint32 dflt)
{
  if (!FIXNUMP (v)) return dflt;
  return (guint32) (XFIXNUM (v) & 0xFFFFFFFF);
}

static float
cmacs_lrg_float (Lisp_Object v, double dflt)
{
  return (float) (NUMBERP (v) ? XFLOATINT (v) : dflt);
}

DEFUN ("cmacs-libregnum-set-focus-policy",
       Fcmacs_libregnum_set_focus_policy,
       Scmacs_libregnum_set_focus_policy, 2, 3, 0,
       doc: /* Set how BUFFER's camera responds to picking.

ON-CLICK non-nil (the default) flies the camera to whatever a left click
hits.  That suits a scene you navigate BY clicking; it is wrong for one
you navigate by looking at, where it snatches the view away from
whatever the click just started.

CONTEXT, a fraction of the whole scene's extent, puts a floor under the
focus distance.  Without it the distance comes from the clicked node's
own size, which says nothing about the scale of the scene around it: a
small node in a large graph gets framed from close enough to fill the
view with one dot and none of its surroundings.  */)
  (Lisp_Object buffer, Lisp_Object on_click, Lisp_Object context)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (!ctx) return Qnil;
  cmacs_libregnum_render_ctx_set_focus_policy
    (ctx, !NILP (on_click),
     NUMBERP (context) ? XFLOATINT (context) : 0.0);
  return NILP (on_click) ? Qnil : Qt;
}

DEFUN ("cmacs-libregnum-set-background",
       Fcmacs_libregnum_set_background,
       Scmacs_libregnum_set_background, 2, 5, 0,
       doc: /* Set what fills BUFFER's viewport behind the scene.

KIND is `none' (the flat default), `solid', `gradient', `starfield',
`nebula' or `image'.  TOP and BOTTOM are 0xRRGGBBAA integers -- `solid'
uses TOP only, the others blend TOP to BOTTOM down the viewport.  PATH is
the image file for `image', which is drawn cover-fit so a wallpaper of
any shape fills the viewport without being squashed.

Returns nil, without changing anything, when `image' is given a path that
is not a readable file: a viewport that goes blank is a worse answer
than one that ignores a bad path.  */)
  (Lisp_Object buffer, Lisp_Object kind, Lisp_Object top,
   Lisp_Object bottom, Lisp_Object path)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  CmacsLibregnumBackgroundKind k = CMACS_LIBREGNUM_BG_NONE;
  gboolean ok;

  if (!ctx) return Qnil;

  if (EQ (kind, Qcmacs_bg_solid))          k = CMACS_LIBREGNUM_BG_SOLID;
  else if (EQ (kind, Qcmacs_bg_gradient))  k = CMACS_LIBREGNUM_BG_GRADIENT;
  else if (EQ (kind, Qcmacs_bg_starfield)) k = CMACS_LIBREGNUM_BG_STARFIELD;
  else if (EQ (kind, Qcmacs_bg_nebula))    k = CMACS_LIBREGNUM_BG_NEBULA;
  else if (EQ (kind, Qimage))              k = CMACS_LIBREGNUM_BG_IMAGE;

  ok = cmacs_libregnum_render_ctx_set_background
         (ctx, k,
          cmacs_lrg_rgba (top, 0x101017FFu),
          cmacs_lrg_rgba (bottom, 0x05050AFFu),
          STRINGP (path) ? SSDATA (ENCODE_FILE (path)) : NULL);

  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return ok ? kind : Qnil;
}

/* ── Particles ─────────────────────────────────────────────────────
 * Decoration, deliberately: they make a scene feel alive and they must
 * never be load-bearing.  Every entry point is a no-op on a buffer with
 * no view, so a caller need not care whether one is attached yet.  */

DEFUN ("cmacs-libregnum-particles-enable",
       Fcmacs_libregnum_particles_enable,
       Scmacs_libregnum_particles_enable, 1, 2, 0,
       doc: /* Turn particle effects on for BUFFER (ON nil turns them off).
Off is the default and costs nothing: the particle system is not even
created until something asks for it.  Turning them off drops every
emitter and every live particle.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (!ctx) return Qnil;
  cmacs_libregnum_render_ctx_particles_set_enabled (ctx, !NILP (on));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return NILP (on) ? Qnil : Qt;
}

DEFUN ("cmacs-libregnum-particles-clear",
       Fcmacs_libregnum_particles_clear,
       Scmacs_libregnum_particles_clear, 1, 1, 0,
       doc: /* Drop BUFFER's particle emitters and every live particle.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (ctx) cmacs_libregnum_render_ctx_particles_clear (ctx);
  return Qnil;
}

/* The fade colour is the start colour with alpha zeroed.  Deriving it
 * rather than taking it as an argument keeps both DEFUNs inside Emacs's
 * eight-argument ceiling, and a particle that fades to transparent is
 * what every caller wanted anyway. */
static guint32
cmacs_lrg_fade (guint32 rgba)
{
  return rgba & 0xFFFFFF00u;
}

DEFUN ("cmacs-libregnum-particles-emitter",
       Fcmacs_libregnum_particles_emitter,
       Scmacs_libregnum_particles_emitter, 4, 8, 0,
       doc: /* Add a persistent particle emitter to BUFFER at X Y Z.
RADIUS is the sphere particles are born on, RATE how many per second,
COLOR a 0xRRGGBBAA integer they start at (they fade to transparent), and
SIZE their world size.  Returns t when the emitter was added -- nil
means particles are off, which is not an error.  */)
  (Lisp_Object buffer, Lisp_Object x, Lisp_Object y, Lisp_Object z,
   Lisp_Object radius, Lisp_Object rate, Lisp_Object color,
   Lisp_Object size)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (!ctx) return Qnil;
  guint32 c = cmacs_lrg_rgba (color, 0x8FD4FFFFu);
  gboolean ok = cmacs_libregnum_render_ctx_particles_add_emitter
                  (ctx,
                   cmacs_lrg_float (x, 0.0), cmacs_lrg_float (y, 0.0),
                   cmacs_lrg_float (z, 0.0),
                   cmacs_lrg_float (radius, 1.0),
                   cmacs_lrg_float (rate, 6.0),
                   c, cmacs_lrg_fade (c),
                   cmacs_lrg_float (size, 0.12),
                   2.0f, 0.4f);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-particles-burst",
       Fcmacs_libregnum_particles_burst,
       Scmacs_libregnum_particles_burst, 4, 8, 0,
       doc: /* Fire COUNT particles at once from X Y Z in BUFFER.
COLOR is a 0xRRGGBBAA integer they start at (they fade to transparent);
SIZE is their world size and SPEED how fast they fly outward.  Returns t
when anything was emitted.  */)
  (Lisp_Object buffer, Lisp_Object x, Lisp_Object y, Lisp_Object z,
   Lisp_Object count, Lisp_Object color, Lisp_Object size,
   Lisp_Object speed)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  if (!ctx) return Qnil;
  guint n = FIXNUMP (count) ? (guint) max (0, XFIXNUM (count)) : 24u;
  guint32 c = cmacs_lrg_rgba (color, 0xFFE58CFFu);
  gboolean ok = cmacs_libregnum_render_ctx_particles_burst
                  (ctx,
                   cmacs_lrg_float (x, 0.0), cmacs_lrg_float (y, 0.0),
                   cmacs_lrg_float (z, 0.0), n,
                   c, cmacs_lrg_fade (c),
                   cmacs_lrg_float (size, 0.16),
                   0.9f,
                   cmacs_lrg_float (speed, 3.0));
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-particles-count",
       Fcmacs_libregnum_particles_count,
       Scmacs_libregnum_particles_count, 1, 1, 0,
       doc: /* Number of live particles in BUFFER.
The only externally visible proof that a burst did anything, which is
what makes the effect testable at all.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_image_ctx (buffer);
  return make_fixnum (ctx
                      ? (EMACS_INT) cmacs_libregnum_render_ctx_particles_count (ctx)
                      : 0);
}

DEFUN ("cmacs-libregnum-pan", Fcmacs_libregnum_pan,
       Scmacs_libregnum_pan, 3, 3, 0,
       doc: /* Pan BUFFER's camera by DX and DY, in pixels of drag.
Works whether or not orbiting is locked, so a flat view can still be
moved around.  */)
  (Lisp_Object buffer, Lisp_Object dx, Lisp_Object dy)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_pan_camera
    (cmacs_libregnum_view_get_render_ctx (v),
     cmacs_libregnum__to_double (dx), cmacs_libregnum__to_double (dy));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-set-right-drag-pans",
       Fcmacs_libregnum_set_right_drag_pans,
       Scmacs_libregnum_set_right_drag_pans, 2, 2, 0,
       doc: /* Make a right-drag in BUFFER pan when PANS is non-nil.

The default is the CAD navigation profile: either mouse button orbits
and the middle one pans.  With PANS, right-drag pans instead -- what a
map-like scene wants, and what a user with no middle button can
actually reach.  A right-click without movement still opens the context
menu either way.  */)
  (Lisp_Object buffer, Lisp_Object pans)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_right_drag_pans
    (cmacs_libregnum_view_get_render_ctx (v), !NILP (pans));
  return pans;
}

DEFUN ("cmacs-libregnum-set-wheel-up-zooms-in",
       Fcmacs_libregnum_set_wheel_up_zooms_in,
       Scmacs_libregnum_set_wheel_up_zooms_in, 2, 2, 0,
       doc: /* Make the wheel zoom conventionally in BUFFER when UP-ZOOMS-IN.

Scrolling up then moves the camera closer, as it does in every map and
3-D viewer.  The inherited libregnum behaviour is the opposite --
scroll down to move closer -- and is what you get with a nil argument,
so scenes that shipped with it are not flipped underneath them.  */)
  (Lisp_Object buffer, Lisp_Object up_zooms_in)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_wheel_up_zooms_in
    (cmacs_libregnum_view_get_render_ctx (v), !NILP (up_zooms_in));
  return up_zooms_in;
}

DEFUN ("cmacs-libregnum-orbit", Fcmacs_libregnum_orbit,
       Scmacs_libregnum_orbit, 3, 3, 0,
       doc: /* Orbit BUFFER's camera by DX and DY, in pixels of drag.
A no-op when the view has orbiting locked (a flat scene viewed
head-on).  Returns the new camera state.  */)
  (Lisp_Object buffer, Lisp_Object dx, Lisp_Object dy)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_orbit_camera
    (cmacs_libregnum_view_get_render_ctx (v),
     cmacs_libregnum__to_double (dx), cmacs_libregnum__to_double (dy));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-set-orbit-locked", Fcmacs_libregnum_set_orbit_locked,
       Scmacs_libregnum_set_orbit_locked, 2, 2, 0,
       doc: /* Stop BUFFER's camera orbiting when LOCKED is non-nil.
Pan and zoom keep working.  Intended for a scene whose content is
planar and viewed head-on, where tumbling would only reveal that
everything is coplanar.  */)
  (Lisp_Object buffer, Lisp_Object locked)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_orbit_locked
    (cmacs_libregnum_view_get_render_ctx (v), !NILP (locked));
  return locked;
}

DEFUN ("cmacs-libregnum-ink-bbox", Fcmacs_libregnum_ink_bbox,
       Scmacs_libregnum_ink_bbox, 1, 1, 0,
       doc: /* Return the drawn extent of BUFFER's scene as (MINX MINY MAXX MAXY).

Coordinates are view-local pixels in the orientation you see on screen,
so they can be compared directly against `cmacs-libregnum-project'.
Renders a frame synchronously, so it works headless.  Returns nil when
the frame is entirely background.

Intended for automated render verification: a snapshot shows that pixels
changed, this shows where.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
  if (!cmacs_libregnum_render_ctx_ink_bbox
        (cmacs_libregnum_view_get_render_ctx (v), &x0, &y0, &x1, &y1))
    return Qnil;
  return list4 (make_fixnum (x0), make_fixnum (y0),
                make_fixnum (x1), make_fixnum (y1));
}

DEFUN ("cmacs-libregnum-camera-state", Fcmacs_libregnum_camera_state,
       Scmacs_libregnum_camera_state, 1, 1, 0,
       doc: /* Return camera state of BUFFER's libregnum view.
The return value is a plist
  (:position (X Y Z) :target (X Y Z) :fov FOV)
or nil if BUFFER has no attached view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  double px, py, pz, tx, ty, tz, fov;
  cmacs_libregnum_render_ctx_get_camera_state (ctx,
                                                &px, &py, &pz,
                                                &tx, &ty, &tz, &fov);
  return list (intern (":position"),
                list3 (make_float (px), make_float (py), make_float (pz)),
                intern (":target"),
                list3 (make_float (tx), make_float (ty), make_float (tz)),
                intern (":fov"),  make_float (fov));
}

static double
cmacs_libregnum__to_double (Lisp_Object obj)
{
  if (FIXNUMP (obj))  return (double) XFIXNUM (obj);
  if (FLOATP (obj))   return XFLOAT_DATA (obj);
  return 0.0;
}

DEFUN ("cmacs-libregnum-set-camera", Fcmacs_libregnum_set_camera,
       Scmacs_libregnum_set_camera, 4, 4, 0,
       doc: /* Set camera state of BUFFER's libregnum view.
POSITION and TARGET are lists (X Y Z).  FOV is degrees.  */)
  (Lisp_Object buffer, Lisp_Object position, Lisp_Object target,
   Lisp_Object fov)
{
  CHECK_BUFFER (buffer);
  CHECK_CONS (position);
  CHECK_CONS (target);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  double px = cmacs_libregnum__to_double (XCAR (position));
  Lisp_Object py_c = XCDR (position);
  double py = CONSP (py_c) ? cmacs_libregnum__to_double (XCAR (py_c)) : 0.0;
  Lisp_Object pz_c = CONSP (py_c) ? XCDR (py_c) : Qnil;
  double pz = CONSP (pz_c) ? cmacs_libregnum__to_double (XCAR (pz_c)) : 0.0;
  double tx = cmacs_libregnum__to_double (XCAR (target));
  Lisp_Object ty_c = XCDR (target);
  double ty = CONSP (ty_c) ? cmacs_libregnum__to_double (XCAR (ty_c)) : 0.0;
  Lisp_Object tz_c = CONSP (ty_c) ? XCDR (ty_c) : Qnil;
  double tz = CONSP (tz_c) ? cmacs_libregnum__to_double (XCAR (tz_c)) : 0.0;
  double fov_d = cmacs_libregnum__to_double (fov);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_set_camera_state (ctx,
                                                px, py, pz,
                                                tx, ty, tz, fov_d);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

/* Build a NULL-terminated, main()-style argv from a Lisp list of strings.
 * Element 0 is a synthetic program name (PROGNAME) so the vector mirrors a
 * real argv; the list elements (each a string) follow.  Returns a g_strv the
 * caller must g_strfreev, or NULL when LIST is nil/empty.  Signals a Lisp
 * error if any element is not a string. */
static char **
cmacs_libregnum__argv_from_list (Lisp_Object list, const char *progname)
{
  GPtrArray *a;
  Lisp_Object tail;

  if (NILP (list))
    return NULL;
  CHECK_LIST (list);

  a = g_ptr_array_new ();
  g_ptr_array_add (a, g_strdup (progname));
  for (tail = list; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object elt = XCAR (tail);
      CHECK_STRING (elt);
      g_ptr_array_add (a, g_strdup (SSDATA (ENCODE_UTF_8 (elt))));
    }
  g_ptr_array_add (a, NULL);
  return (char **) g_ptr_array_free (a, FALSE);
}

DEFUN ("cmacs-libregnum-load-game", Fcmacs_libregnum_load_game,
       Scmacs_libregnum_load_game, 2, 3, 0,
       doc: /* Load libregnum game module SO-PATH into BUFFER's view.
SO-PATH is the absolute path of a game `.so' built with
LRG_DEFINE_GAME_MODULE.  The game is then driven and rendered into the
view each frame, and the view is switched to animated mode.

Optional ARGV is a list of strings passed verbatim to the module as a
CLI-style argument vector (applied via the libregnum LrgConfigurable
interface before startup), e.g. '("--profile" "warm").  A rejected
argument warns but does not abort the load.  Signals
`cmacs-libregnum-error' on failure.  */)
  (Lisp_Object buffer, Lisp_Object so_path, Lisp_Object argv)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (so_path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  Lisp_Object encoded = ENCODE_FILE (so_path);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  char **cargv = cmacs_libregnum__argv_from_list (argv, "cmacs-libregnum");
  char *err = NULL;
  bool ok = cmacs_libregnum_render_ctx_load_game (ctx, SSDATA (encoded),
                                                  (const char *const *) cargv,
                                                  &err);
  g_strfreev (cargv);
  if (!ok)
    {
      Lisp_Object msg = build_string (err ? err : "load-game failed");
      g_free (err);
      xsignal1 (Qcmacs_libregnum_error, msg);
    }
  cmacs_libregnum_view_set_animated (v, 1, 60);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-unload-game", Fcmacs_libregnum_unload_game,
       Scmacs_libregnum_unload_game, 1, 1, 0,
       doc: /* Unload the game module from BUFFER's view, if one is loaded.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_unload_game (ctx);
  cmacs_libregnum_view_set_animated (v, 0, 60);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-game-loaded-p", Fcmacs_libregnum_game_loaded_p,
       Scmacs_libregnum_game_loaded_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's view is hosting a game module.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_is_game (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-game-key", Fcmacs_libregnum_game_key,
       Scmacs_libregnum_game_key, 3, 3, 0,
       doc: /* Forward key GRL-KEY to the game hosted in BUFFER's view.
GRL-KEY is the integer graylib key code (GrlKey).  PRESS non-nil means a
press, nil a release.  A minor mode on the game buffer maps Emacs key
events to these calls (Emacs owns the keymap, so keyboard input is routed
from Elisp rather than read from the hidden window).  */)
  (Lisp_Object buffer, Lisp_Object grl_key, Lisp_Object press)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (grl_key);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_game_key (ctx, (int) XFIXNUM (grl_key),
                                       !NILP (press));
  return Qt;
}

/* ── Editor / level authoring ──────────────────────────────────────
 * Drive the engine LrgEditor hosted in BUFFER's view.  The level is
 * baked into the scene drawables, so the existing scene render/pick
 * path and `cmacs-libregnum-tree-nodes' double as the editor viewport
 * and outliner.  Node ids are the scene-node ids. */

DEFUN ("cmacs-libregnum-editor-new", Fcmacs_libregnum_editor_new,
       Scmacs_libregnum_editor_new, 1, 1, 0,
       doc: /* Start a fresh, empty editable level in BUFFER's view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_new (ctx))
    xsignal1 (Qcmacs_libregnum_error, build_string ("editor unavailable"));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-open", Fcmacs_libregnum_editor_open,
       Scmacs_libregnum_editor_open, 2, 2, 0,
       doc: /* Open `.rlevel' file PATH as an editable level in BUFFER's view.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  Lisp_Object encoded = ENCODE_FILE (path);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  char *err = NULL;
  if (!cmacs_libregnum_render_ctx_editor_open (ctx, SSDATA (encoded), &err))
    {
      Lisp_Object msg = build_string (err ? err : "open failed");
      g_free (err);
      xsignal1 (Qcmacs_libregnum_error, msg);
    }
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-save", Fcmacs_libregnum_editor_save,
       Scmacs_libregnum_editor_save, 2, 2, 0,
       doc: /* Save BUFFER's view editable level to `.rlevel' file PATH.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  Lisp_Object encoded = ENCODE_FILE (path);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  char *err = NULL;
  if (!cmacs_libregnum_render_ctx_editor_save (ctx, SSDATA (encoded), &err))
    {
      Lisp_Object msg = build_string (err ? err : "save failed");
      g_free (err);
      xsignal1 (Qcmacs_libregnum_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-active-p", Fcmacs_libregnum_editor_active_p,
       Scmacs_libregnum_editor_active_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's view is hosting an editable level.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_editor_active (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-add-primitive", Fcmacs_libregnum_editor_add_primitive,
       Scmacs_libregnum_editor_add_primitive, 2, 3, 0,
       doc: /* Add a primitive node (PRIM is an LrgPrimitiveType int) to BUFFER's
level and select it.  Optional NAME names the node.  Returns the new node's
scene id, or nil on failure.  */)
  (Lisp_Object buffer, Lisp_Object prim, Lisp_Object name)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (prim);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  const char *nm = NILP (name) ? NULL : (CHECK_STRING (name), SSDATA (name));
  gint id = cmacs_libregnum_render_ctx_editor_add_primitive
              (ctx, (int) XFIXNUM (prim), nm);
  cmacs_libregnum_view_request_redraw (v);
  return (id < 0) ? Qnil : make_fixnum (id);
}

DEFUN ("cmacs-libregnum-editor-delete", Fcmacs_libregnum_editor_delete,
       Scmacs_libregnum_editor_delete, 2, 2, 0,
       doc: /* Delete scene node NODE-ID from BUFFER's editable level.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_delete (ctx, (gint) XFIXNUM (node_id));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-select", Fcmacs_libregnum_editor_select,
       Scmacs_libregnum_editor_select, 2, 2, 0,
       doc: /* Select scene node NODE-ID in BUFFER's editable level.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_select_node (ctx, (gint) XFIXNUM (node_id));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-set-position", Fcmacs_libregnum_editor_set_position,
       Scmacs_libregnum_editor_set_position, 5, 5, 0,
       doc: /* Set scene node NODE-ID's local position to (X Y Z) as one
undoable edit, in BUFFER's editable level.  */)
  (Lisp_Object buffer, Lisp_Object node_id,
   Lisp_Object x, Lisp_Object y, Lisp_Object z)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_position
    (ctx, (gint) XFIXNUM (node_id),
     cmacs_libregnum__to_double (x),
     cmacs_libregnum__to_double (y),
     cmacs_libregnum__to_double (z));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-undo", Fcmacs_libregnum_editor_undo,
       Scmacs_libregnum_editor_undo, 1, 1, 0,
       doc: /* Undo the last edit in BUFFER's editable level.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_undo (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-redo", Fcmacs_libregnum_editor_redo,
       Scmacs_libregnum_editor_redo, 1, 1, 0,
       doc: /* Redo the last undone edit in BUFFER's editable level.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_redo (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-refresh", Fcmacs_libregnum_editor_refresh,
       Scmacs_libregnum_editor_refresh, 1, 1, 0,
       doc: /* Rebuild BUFFER's editor scene from its level.
Re-bakes every node (CAD parts re-evaluate through the CAD manager's
cache; call `cmacs-libregnum-cad-invalidate' first to force a fresh
evaluation after a source change).  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_refresh (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

#ifdef HAVE_CMACS_CAD
DEFUN ("cmacs-libregnum-cad-invalidate", Fcmacs_libregnum_cad_invalidate,
       Scmacs_libregnum_cad_invalidate, 1, 1, 0,
       doc: /* Drop the CAD manager's caches for the part source at PATH.
The next editor rebuild re-evaluates the part (use after the .cad
source changed).  */)
  (Lisp_Object path)
{
  CHECK_STRING (path);
  cmacs_libregnum_render_cad_invalidate (SSDATA (path));
  return Qt;
}
DEFUN ("cmacs-libregnum-cad-set-source", Fcmacs_libregnum_cad_set_source,
       Scmacs_libregnum_cad_set_source, 2, 2, 0,
       doc: /* Push SOURCE as the in-memory text for the part at PATH.
The viewport's next rebuild bakes SOURCE (typically the unsaved
buffer) instead of the on-disk file.  */)
  (Lisp_Object path, Lisp_Object source)
{
  GError *error = NULL;
  CHECK_STRING (path);
  CHECK_STRING (source);
  if (!cmacs_libregnum_render_cad_set_source (SSDATA (path),
                                              SSDATA (source), &error))
    {
      Lisp_Object msg = build_string (error ? error->message : "CAD error");
      if (error) g_error_free (error);
      xsignal1 (Qerror, msg);
    }
  return Qt;
}
#endif /* HAVE_CMACS_CAD */

DEFUN ("cmacs-libregnum-editor-can-undo-p", Fcmacs_libregnum_editor_can_undo_p,
       Scmacs_libregnum_editor_can_undo_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's editable level has an edit to undo.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_editor_can_undo (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-guid", Fcmacs_libregnum_editor_node_guid,
       Scmacs_libregnum_editor_node_guid, 2, 2, 0,
       doc: /* Return the stable guid string of scene NODE-ID in BUFFER's
editable level, or nil.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  const char *guid = cmacs_libregnum_render_ctx_editor_node_guid
                       (ctx, (gint) XFIXNUM (node_id));
  return guid ? build_string (guid) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-location",
       Fcmacs_libregnum_editor_node_location,
       Scmacs_libregnum_editor_node_location, 2, 2, 0,
       doc: /* Return scene NODE-ID's local location as a list (X Y Z) of
floats in BUFFER's editable level, or nil if NODE-ID is invalid.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  double x = 0, y = 0, z = 0;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_node_location
        (ctx, (gint) XFIXNUM (node_id), &x, &y, &z))
    return Qnil;
  return list3 (make_float (x), make_float (y), make_float (z));
}

DEFUN ("cmacs-libregnum-editor-selected-id",
       Fcmacs_libregnum_editor_selected_id,
       Scmacs_libregnum_editor_selected_id, 1, 1, 0,
       doc: /* Return the selected scene node id in BUFFER's editable level,
or nil if nothing is selected.  Reflects viewport picks as well as Lisp
selection, so it is the single source of the current selection.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gint id = cmacs_libregnum_render_ctx_get_selected (ctx);
  return (id >= 0) ? make_fixnum (id) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-set-snap", Fcmacs_libregnum_editor_set_snap,
       Scmacs_libregnum_editor_set_snap, 2, 2, 0,
       doc: /* Set the translate grid SNAP (a number, or nil/0 to disable) for
drag-to-move in BUFFER's editable level.  */)
  (Lisp_Object buffer, Lisp_Object snap)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_snap
    (ctx, NILP (snap) ? 0.0 : cmacs_libregnum__to_double (snap));
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-focus", Fcmacs_libregnum_editor_focus,
       Scmacs_libregnum_editor_focus, 2, 2, 0,
       doc: /* Frame the camera on scene NODE-ID in BUFFER (animated).  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_focus_node (ctx, (gint) XFIXNUM (node_id));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-drag-begin", Fcmacs_libregnum_editor_drag_begin,
       Scmacs_libregnum_editor_drag_begin, 6, 6, 0,
       doc: /* Begin dragging NODE-ID in BUFFER, grabbed at view-local pixel
\(VX,VY) in a VW-by-VH viewport.  The node moves on the horizontal plane at
its current height.  Returns non-nil on success.  Mainly for the C input
layer + scripting/tests; interactive use is the mouse itself.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object vx, Lisp_Object vy,
   Lisp_Object vw, Lisp_Object vh)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_drag_begin
                  (ctx, (gint) XFIXNUM (node_id),
                   cmacs_libregnum__to_double (vx),
                   cmacs_libregnum__to_double (vy),
                   (int) XFIXNUM (vw), (int) XFIXNUM (vh));
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-drag-update", Fcmacs_libregnum_editor_drag_update,
       Scmacs_libregnum_editor_drag_update, 5, 5, 0,
       doc: /* Track an in-progress drag in BUFFER to view-local (VX,VY) in a
VW-by-VH viewport (live, no undo entry).  Returns non-nil on success.  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy,
   Lisp_Object vw, Lisp_Object vh)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_drag_update
                  (ctx, cmacs_libregnum__to_double (vx),
                   cmacs_libregnum__to_double (vy),
                   (int) XFIXNUM (vw), (int) XFIXNUM (vh));
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-drag-end", Fcmacs_libregnum_editor_drag_end,
       Scmacs_libregnum_editor_drag_end, 1, 1, 0,
       doc: /* Finish the in-progress drag in BUFFER, recording one coalesced
undoable move (a no-op drag records nothing).  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_drag_end (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-node-rotation",
       Fcmacs_libregnum_editor_node_rotation,
       Scmacs_libregnum_editor_node_rotation, 2, 2, 0,
       doc: /* Return NODE-ID's local rotation as a list (X Y Z) of euler
radians in BUFFER's editable level, or nil if NODE-ID is invalid.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  double x = 0, y = 0, z = 0;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_node_rotation
        (ctx, (gint) XFIXNUM (node_id), &x, &y, &z))
    return Qnil;
  return list3 (make_float (x), make_float (y), make_float (z));
}

DEFUN ("cmacs-libregnum-editor-node-scale",
       Fcmacs_libregnum_editor_node_scale,
       Scmacs_libregnum_editor_node_scale, 2, 2, 0,
       doc: /* Return NODE-ID's local scale as a list (X Y Z) in BUFFER's
editable level, or nil if NODE-ID is invalid.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  double x = 1, y = 1, z = 1;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_node_scale
        (ctx, (gint) XFIXNUM (node_id), &x, &y, &z))
    return Qnil;
  return list3 (make_float (x), make_float (y), make_float (z));
}

DEFUN ("cmacs-libregnum-editor-set-rotation",
       Fcmacs_libregnum_editor_set_rotation,
       Scmacs_libregnum_editor_set_rotation, 5, 5, 0,
       doc: /* Set NODE-ID's local rotation to (X Y Z) euler radians as one
undoable edit, in BUFFER's editable level.  */)
  (Lisp_Object buffer, Lisp_Object node_id,
   Lisp_Object x, Lisp_Object y, Lisp_Object z)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_rotation
    (ctx, (gint) XFIXNUM (node_id),
     cmacs_libregnum__to_double (x),
     cmacs_libregnum__to_double (y),
     cmacs_libregnum__to_double (z));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-set-scale", Fcmacs_libregnum_editor_set_scale,
       Scmacs_libregnum_editor_set_scale, 5, 5, 0,
       doc: /* Set NODE-ID's local scale to (X Y Z) as one undoable edit, in
BUFFER's editable level.  */)
  (Lisp_Object buffer, Lisp_Object node_id,
   Lisp_Object x, Lisp_Object y, Lisp_Object z)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_scale
    (ctx, (gint) XFIXNUM (node_id),
     cmacs_libregnum__to_double (x),
     cmacs_libregnum__to_double (y),
     cmacs_libregnum__to_double (z));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-reparent", Fcmacs_libregnum_editor_reparent,
       Scmacs_libregnum_editor_reparent, 3, 3, 0,
       doc: /* Reparent CHILD-ID under PARENT-ID in BUFFER's editable level
(PARENT-ID negative == the level root).  Returns non-nil on success.  */)
  (Lisp_Object buffer, Lisp_Object child_id, Lisp_Object parent_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (child_id);
  CHECK_FIXNUM (parent_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_reparent
                  (ctx, (gint) XFIXNUM (child_id), (gint) XFIXNUM (parent_id));
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-add-visual", Fcmacs_libregnum_editor_add_visual,
       Scmacs_libregnum_editor_add_visual, 2, 4, 0,
       doc: /* Add a node of visual KIND (an `LrgNodeVisualKind' int) to
BUFFER's level, with optional ASSET path (for mesh/sprite) and NAME, and select
it.  Returns the new node's scene id, or nil.  KIND: 2 mesh, 3 sprite, 5 light,
6 camera, 7 audio, 8 prefab.  */)
  (Lisp_Object buffer, Lisp_Object kind, Lisp_Object asset, Lisp_Object name)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (kind);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gint id = cmacs_libregnum_render_ctx_editor_add_visual
              (ctx, (int) XFIXNUM (kind),
               STRINGP (asset) ? SSDATA (asset) : NULL,
               STRINGP (name) ? SSDATA (name) : NULL);
  cmacs_libregnum_view_request_redraw (v);
  return (id >= 0) ? make_fixnum (id) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-attach-script",
       Fcmacs_libregnum_editor_attach_script,
       Scmacs_libregnum_editor_attach_script, 4, 4, 0,
       doc: /* Attach a script to NODE-ID in BUFFER: LANGUAGE is an
`LrgScriptLanguage' int (1 lua, 2 python, 3 gjs, 4 crispy) and PATH the script
file.  Persisted in the level.  Returns non-nil on success.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object language,
   Lisp_Object path)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_FIXNUM (language);
  CHECK_STRING (path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_attach_script
                  (ctx, (gint) XFIXNUM (node_id), (int) XFIXNUM (language),
                   SSDATA (path));
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-script-count",
       Fcmacs_libregnum_editor_node_script_count,
       Scmacs_libregnum_editor_node_script_count, 2, 2, 0,
       doc: /* Return the number of scripts attached to NODE-ID in BUFFER, or
nil if NODE-ID is invalid.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gint n = cmacs_libregnum_render_ctx_editor_node_script_count
             (ctx, (gint) XFIXNUM (node_id));
  return (n >= 0) ? make_fixnum (n) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-play", Fcmacs_libregnum_editor_play,
       Scmacs_libregnum_editor_play, 1, 1, 0,
       doc: /* Play-in-editor: instantiate BUFFER's level into a throwaway
runtime world and run it (the level document is not mutated).  Returns non-nil
on success.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_play (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-stop", Fcmacs_libregnum_editor_stop,
       Scmacs_libregnum_editor_stop, 1, 1, 0,
       doc: /* Stop play-in-editor in BUFFER and discard the runtime world.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_stop (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-playing-p", Fcmacs_libregnum_editor_playing_p,
       Scmacs_libregnum_editor_playing_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's level is in play-in-editor mode.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_editor_playing (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-play-tick", Fcmacs_libregnum_editor_play_tick,
       Scmacs_libregnum_editor_play_tick, 2, 2, 0,
       doc: /* Advance BUFFER's play-in-editor world by DELTA seconds.  */)
  (Lisp_Object buffer, Lisp_Object delta)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_play_tick
                  (ctx, cmacs_libregnum__to_double (delta));
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-set-view-2d",
       Fcmacs_libregnum_editor_set_view_2d,
       Scmacs_libregnum_editor_set_view_2d, 2, 2, 0,
       doc: /* Switch BUFFER's viewport to a top-down orthographic 2D view when
ON is non-nil, else back to the default perspective.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_view_2d (ctx, !NILP (on));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-view-2d-p", Fcmacs_libregnum_editor_view_2d_p,
       Scmacs_libregnum_editor_view_2d_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's viewport is in 2D (orthographic) view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_editor_view_2d (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-set-armed", Fcmacs_libregnum_editor_set_armed,
       Scmacs_libregnum_editor_set_armed, 2, 2, 0,
       doc: /* Arm BUFFER (ON non-nil) so the next viewport click drops the
pending asset at the clicked ground point (C defers to
`cmacs-libregnum-editor--drop').  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_armed (ctx, !NILP (on));
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-screen-to-ground",
       Fcmacs_libregnum_editor_screen_to_ground,
       Scmacs_libregnum_editor_screen_to_ground, 5, 5, 0,
       doc: /* World point on the ground plane under view-local (VX,VY) in a
VW-by-VH viewport of BUFFER, as a list (X Y Z), or nil.  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy,
   Lisp_Object vw, Lisp_Object vh)
{
  double x = 0, y = 0, z = 0;
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_screen_to_ground
        (ctx, cmacs_libregnum__to_double (vx),
         cmacs_libregnum__to_double (vy),
         (int) XFIXNUM (vw), (int) XFIXNUM (vh), &x, &y, &z))
    return Qnil;
  return list3 (make_float (x), make_float (y), make_float (z));
}

DEFUN ("cmacs-libregnum-project", Fcmacs_libregnum_project,
       Scmacs_libregnum_project, 6, 6, 0,
       doc: /* Project world point (WX WY WZ) in BUFFER to view-local pixels in
a VW-by-VH viewport.  Returns (SX SY) floats, or nil if behind the camera.  */)
  (Lisp_Object buffer, Lisp_Object wx, Lisp_Object wy, Lisp_Object wz,
   Lisp_Object vw, Lisp_Object vh)
{
  double sx = 0, sy = 0;
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_project
        (ctx, (float) cmacs_libregnum__to_double (wx),
         (float) cmacs_libregnum__to_double (wy),
         (float) cmacs_libregnum__to_double (wz),
         (int) XFIXNUM (vw), (int) XFIXNUM (vh), &sx, &sy))
    return Qnil;
  return list2 (make_float (sx), make_float (sy));
}

DEFUN ("cmacs-libregnum-editor-set-tool", Fcmacs_libregnum_editor_set_tool,
       Scmacs_libregnum_editor_set_tool, 2, 2, 0,
       doc: /* Set BUFFER's gizmo TOOL: 0 select, 1 translate, 2 rotate,
3 scale.  The handles draw over the selection in the viewport.  */)
  (Lisp_Object buffer, Lisp_Object tool)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (tool);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_tool (ctx, (int) XFIXNUM (tool));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-get-tool", Fcmacs_libregnum_editor_get_tool,
       Scmacs_libregnum_editor_get_tool, 1, 1, 0,
       doc: /* Return BUFFER's current gizmo tool (0..3).  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return make_fixnum (cmacs_libregnum_render_ctx_editor_get_tool (ctx));
}

DEFUN ("cmacs-libregnum-editor-gizmo-begin",
       Fcmacs_libregnum_editor_gizmo_begin,
       Scmacs_libregnum_editor_gizmo_begin, 5, 5, 0,
       doc: /* Begin a gizmo drag in BUFFER if a handle is under view-local
\(VX,VY) in a VW-by-VH viewport.  Returns non-nil if a handle was grabbed.
Mainly for the C input layer + scripting/tests.  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy,
   Lisp_Object vw, Lisp_Object vh)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_gizmo_begin
                  (ctx, cmacs_libregnum__to_double (vx),
                   cmacs_libregnum__to_double (vy),
                   (int) XFIXNUM (vw), (int) XFIXNUM (vh));
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-gizmo-drag", Fcmacs_libregnum_editor_gizmo_drag,
       Scmacs_libregnum_editor_gizmo_drag, 5, 5, 0,
       doc: /* Track an in-progress gizmo drag in BUFFER to view-local (VX,VY)
in a VW-by-VH viewport (live, no undo entry).  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy,
   Lisp_Object vw, Lisp_Object vh)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_gizmo_drag
                  (ctx, cmacs_libregnum__to_double (vx),
                   cmacs_libregnum__to_double (vy),
                   (int) XFIXNUM (vw), (int) XFIXNUM (vh));
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-gizmo-end", Fcmacs_libregnum_editor_gizmo_end,
       Scmacs_libregnum_editor_gizmo_end, 1, 1, 0,
       doc: /* Finish the in-progress gizmo drag in BUFFER (one coalesced undo
step).  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_gizmo_end (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-tilemap-config",
       Fcmacs_libregnum_editor_tilemap_config,
       Scmacs_libregnum_editor_tilemap_config, 8, 8, 0,
       doc: /* Configure NODE-ID in BUFFER as a tilemap: TILESET image,
TILE-W x TILE-H tile pixels, COLS tileset columns, MAP-W x MAP-H cells.  Tiles
within the overlap survive a resize.  Persisted in the level.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object tileset,
   Lisp_Object tile_w, Lisp_Object tile_h, Lisp_Object cols,
   Lisp_Object map_w, Lisp_Object map_h)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_tilemap_config
    (ctx, (gint) XFIXNUM (node_id),
     STRINGP (tileset) ? SSDATA (tileset) : NULL,
     (int) XFIXNUM (tile_w), (int) XFIXNUM (tile_h), (int) XFIXNUM (cols),
     (int) XFIXNUM (map_w), (int) XFIXNUM (map_h));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-tilemap-set-tile",
       Fcmacs_libregnum_editor_tilemap_set_tile,
       Scmacs_libregnum_editor_tilemap_set_tile, 5, 5, 0,
       doc: /* Paint cell (CX,CY) of tilemap NODE-ID in BUFFER with TILE
\(-1 clears).  Persisted in the level.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object cx, Lisp_Object cy,
   Lisp_Object tile)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_FIXNUM (cx);
  CHECK_FIXNUM (cy);
  CHECK_FIXNUM (tile);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_tilemap_set_tile
    (ctx, (gint) XFIXNUM (node_id), (int) XFIXNUM (cx), (int) XFIXNUM (cy),
     (int) XFIXNUM (tile));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-tilemap-info",
       Fcmacs_libregnum_editor_tilemap_info,
       Scmacs_libregnum_editor_tilemap_info, 2, 2, 0,
       doc: /* Return NODE-ID's tilemap dimensions in BUFFER as a plist
\(:map-w W :map-h H :cols C :tile-w TW :tile-h TH), or nil if NODE-ID is not a
tilemap.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  int mw = 0, mh = 0, cols = 0, tw = 0, th = 0;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_tilemap_info
        (ctx, (gint) XFIXNUM (node_id), &mw, &mh, &cols, &tw, &th))
    return Qnil;
  return CALLN (Flist,
                intern (":map-w"), make_fixnum (mw),
                intern (":map-h"), make_fixnum (mh),
                intern (":cols"), make_fixnum (cols),
                intern (":tile-w"), make_fixnum (tw),
                intern (":tile-h"), make_fixnum (th));
}

DEFUN ("cmacs-libregnum-editor-node-object",
       Fcmacs_libregnum_editor_node_object,
       Scmacs_libregnum_editor_node_object, 2, 2, 0,
       doc: /* Return NODE-ID's live engine object in BUFFER as a wrapped
GObject (for `gobject-list-properties' / `gobject-get' / `gobject-set'), or
nil.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  void *obj;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  obj = cmacs_libregnum_render_ctx_editor_node_object (ctx,
          (gint) XFIXNUM (node_id));
  if (!obj) return Qnil;
  return cmacs_gobject_wrap ((GObject *) obj);   /* takes the fresh ref */
}

DEFUN ("cmacs-libregnum-editor-save-prefab",
       Fcmacs_libregnum_editor_save_prefab,
       Scmacs_libregnum_editor_save_prefab, 3, 3, 0,
       doc: /* Save NODE-ID's subtree in BUFFER to a .rprefab FILE.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object file)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_STRING (file);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_editor_save_prefab
           (ctx, (gint) XFIXNUM (node_id), SSDATA (file)) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-instantiate-prefab",
       Fcmacs_libregnum_editor_instantiate_prefab,
       Scmacs_libregnum_editor_instantiate_prefab, 2, 3, 0,
       doc: /* Instantiate .rprefab FILE in BUFFER under PARENT-ID (nil/-1 =
root).  Return the new node id, or nil.  */)
  (Lisp_Object buffer, Lisp_Object file, Lisp_Object parent_id)
{
  gint pid, nid;
  CHECK_BUFFER (buffer);
  CHECK_STRING (file);
  pid = (FIXNUMP (parent_id)) ? (gint) XFIXNUM (parent_id) : -1;
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  nid = cmacs_libregnum_render_ctx_editor_instantiate_prefab
          (ctx, SSDATA (file), pid);
  cmacs_libregnum_view_request_redraw (v);
  return (nid >= 0) ? make_fixnum (nid) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-import-scene",
       Fcmacs_libregnum_editor_import_scene,
       Scmacs_libregnum_editor_import_scene, 2, 2, 0,
       doc: /* Import a Blender-exported scene YAML FILE into BUFFER's editor as
the current level.  */)
  (Lisp_Object buffer, Lisp_Object file)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (file);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_import_scene (ctx, SSDATA (file)))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-scripting-languages",
       Fcmacs_libregnum_scripting_languages,
       Scmacs_libregnum_scripting_languages, 0, 0, 0,
       doc: /* Return available scripting backends as an alist (NAME . LANG-INT),
e.g. (("Crispy" . 4)).  Reflects what libregnum was built with.  */)
  (void)
{
  gint n = cmacs_libregnum_scripting_language_count ();
  gint i;
  Lisp_Object result = Qnil;
  for (i = 0; i < n; i++)
    {
      gint lang = cmacs_libregnum_scripting_language_at (i);
      char *name = cmacs_libregnum_scripting_language_name (i);
      if (name)
        {
          result = Fcons (Fcons (build_string (name), make_fixnum (lang)),
                          result);
          g_free (name);
        }
    }
  return Fnreverse (result);
}

DEFUN ("cmacs-libregnum-project-create", Fcmacs_libregnum_project_create,
       Scmacs_libregnum_project_create, 2, 4, 0,
       doc: /* Create a project manifest (project.ryaml) under ROOT named NAME.
Optional DEFAULT-LEVEL (relative path) and GAME-OUTPUT (.so path).  */)
  (Lisp_Object root, Lisp_Object name, Lisp_Object default_level,
   Lisp_Object game_output)
{
  CHECK_STRING (root);
  CHECK_STRING (name);
  return cmacs_libregnum_project_create
           (SSDATA (root), SSDATA (name),
            STRINGP (default_level) ? SSDATA (default_level) : NULL,
            STRINGP (game_output) ? SSDATA (game_output) : NULL) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-open-project",
       Fcmacs_libregnum_editor_open_project,
       Scmacs_libregnum_editor_open_project, 2, 2, 0,
       doc: /* Open the project at ROOT in BUFFER's editor and load its default
level.  */)
  (Lisp_Object buffer, Lisp_Object root)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (root);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_open_project (ctx, SSDATA (root)))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-assetdb-scan", Fcmacs_libregnum_assetdb_scan,
       Scmacs_libregnum_assetdb_scan, 1, 1, 0,
       doc: /* Scan DIR and return its assets as a list of plists
\(:path P :name N :guid G :type TYPE-INT).  TYPE: 1 texture, 2 model, 3 audio,
4 font, 5 script, 6 level, 7 prefab, 8 tileset, 9 scene.  */)
  (Lisp_Object dir)
{
  void *db;
  gint n, i;
  Lisp_Object result = Qnil;
  CHECK_STRING (dir);
  db = cmacs_libregnum_assetdb_scan (SSDATA (dir));
  if (!db) return Qnil;
  n = cmacs_libregnum_assetdb_count (db);
  for (i = 0; i < n; i++)
    {
      char *path = cmacs_libregnum_assetdb_entry (db, i, 0);
      char *name = cmacs_libregnum_assetdb_entry (db, i, 1);
      char *guid = cmacs_libregnum_assetdb_entry (db, i, 2);
      gint  type = cmacs_libregnum_assetdb_entry_type (db, i);
      result = Fcons (CALLN (Flist,
                             intern (":path"),
                             path ? build_string (path) : Qnil,
                             intern (":name"),
                             name ? build_string (name) : Qnil,
                             intern (":guid"),
                             guid ? build_string (guid) : Qnil,
                             intern (":type"), make_fixnum (type)),
                      result);
      g_free (path); g_free (name); g_free (guid);
    }
  cmacs_libregnum_assetdb_free (db);
  return Fnreverse (result);
}

DEFUN ("cmacs-libregnum-editor-set-visual-param",
       Fcmacs_libregnum_editor_set_visual_param,
       Scmacs_libregnum_editor_set_visual_param, 4, 4, 0,
       doc: /* Set numeric visual param NAME to VALUE on NODE-ID in BUFFER.
For lights: "range" + "r"/"g"/"b" (0-255); cameras: "fov"; audio: "range".
The viewport gizmos update to reflect it.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object name, Lisp_Object value)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_STRING (name);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_visual_param
    (ctx, (gint) XFIXNUM (node_id), SSDATA (name),
     cmacs_libregnum__to_double (value));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-set-visual-param-undoable",
       Fcmacs_libregnum_editor_set_visual_param_undoable,
       Scmacs_libregnum_editor_set_visual_param_undoable, 4, 5, 0,
       doc: /* Set numeric visual param NAME to VALUE on NODE-ID in BUFFER as
an UNDOABLE editor command (so `cmacs-libregnum-editor-undo' reverts it).
With non-nil MERGE, coalesce onto the previous command -- a continuing
slider drag becomes a single undo step.  Returns t on success.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object name,
   Lisp_Object value, Lisp_Object merge)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_STRING (name);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_set_visual_param_undoable
    (ctx, (gint) XFIXNUM (node_id), SSDATA (name),
     cmacs_libregnum__to_double (value), !NILP (merge));
  cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-asset",
       Fcmacs_libregnum_editor_node_asset,
       Scmacs_libregnum_editor_node_asset, 2, 2, 0,
       doc: /* Return NODE-ID's visual asset path in BUFFER (sound/mesh/sprite/
tileset), or nil.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  char *asset;
  Lisp_Object r;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  asset = cmacs_libregnum_render_ctx_editor_node_asset
            (ctx, (gint) XFIXNUM (node_id));
  if (!asset) return Qnil;
  r = build_string (asset);
  g_free (asset);
  return r;
}

DEFUN ("cmacs-libregnum-editor-node-kind",
       Fcmacs_libregnum_editor_node_kind,
       Scmacs_libregnum_editor_node_kind, 2, 2, 0,
       doc: /* Return NODE-ID's visual kind in BUFFER as an integer.
The value matches the `cmacs-libregnum-visual-*' constants (1 = a primitive
shape).  Returns nil for a group node with no visual, or an unknown id.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  gint kind;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  kind = cmacs_libregnum_render_ctx_editor_node_kind
           (ctx, (gint) XFIXNUM (node_id));
  if (kind < 0) return Qnil;
  return make_fixnum (kind);
}

DEFUN ("cmacs-libregnum-editor-node-primitive",
       Fcmacs_libregnum_editor_node_primitive,
       Scmacs_libregnum_editor_node_primitive, 2, 2, 0,
       doc: /* Return NODE-ID's LrgPrimitiveType in BUFFER as an integer
(see the `cmacs-libregnum-primitive-*' constants), or nil when the node is not
a primitive shape.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  gint prim;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  prim = cmacs_libregnum_render_ctx_editor_node_primitive
           (ctx, (gint) XFIXNUM (node_id));
  if (prim < 0) return Qnil;
  return make_fixnum (prim);
}

DEFUN ("cmacs-libregnum-editor-set-name",
       Fcmacs_libregnum_editor_set_name,
       Scmacs_libregnum_editor_set_name, 3, 3, 0,
       doc: /* Rename NODE-ID in BUFFER to NAME (a string) and re-bake the
level so the outliner and other baked labels show the new name.  Returns NAME.
The plain GObject `name' property would not refresh the cached labels.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object name)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_STRING (name);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_name
    (ctx, (gint) XFIXNUM (node_id), SSDATA (name));
  return name;
}

DEFUN ("cmacs-libregnum-set-mouse-capture",
       Fcmacs_libregnum_set_mouse_capture,
       Scmacs_libregnum_set_mouse_capture, 2, 2, 0,
       doc: /* Set whether BUFFER's view captures ALL mouse input while focused.
When CAPTURE is non-nil the view grabs every mouse click on the frame ("full
focus") -- appropriate for a game.  When nil (the default) the view only
handles events inside its own window, so clicks in other Emacs panes select
them normally -- appropriate for the editor.  Returns CAPTURE.  */)
  (Lisp_Object buffer, Lisp_Object capture)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_libregnum_render_ctx_set_mouse_capture_all
    (cmacs_libregnum_view_get_render_ctx (v), !NILP (capture));
  return capture;
}

DEFUN ("cmacs-libregnum-snapshot", Fcmacs_libregnum_snapshot,
       Scmacs_libregnum_snapshot, 2, 2, 0,
       doc: /* Render BUFFER's view and write it to PATH as a PNG.
Synchronous (renders + reads back immediately), so it works for headless or
automated render verification without a compositor screenshot.  Signals
`cmacs-libregnum-error' on failure.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  Lisp_Object encoded = ENCODE_FILE (path);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  char *err = NULL;
  if (!cmacs_libregnum_render_ctx_snapshot_png (ctx, SSDATA (encoded), &err))
    {
      Lisp_Object msg = build_string (err ? err : "snapshot failed");
      g_free (err);
      xsignal1 (Qcmacs_libregnum_error, msg);
    }
  return Qt;
}

/* ── Context-menu / authoring primitives ────────────────────────────── */

DEFUN ("cmacs-libregnum-editor-set-color",
       Fcmacs_libregnum_editor_set_color,
       Scmacs_libregnum_editor_set_color, 6, 6, 0,
       doc: /* Set the material color of NODE-ID in BUFFER.
R G B A are floats 0..1.  Creates a material if the node has none.
Returns t on success, nil if NODE-ID is invalid or has no visual.  */)
  (Lisp_Object buffer, Lisp_Object node_id,
   Lisp_Object r, Lisp_Object g, Lisp_Object b, Lisp_Object a)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_set_color
                  (ctx, (gint) XFIXNUM (node_id),
                   (float) cmacs_libregnum__to_double (r),
                   (float) cmacs_libregnum__to_double (g),
                   (float) cmacs_libregnum__to_double (b),
                   (float) cmacs_libregnum__to_double (a));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-color",
       Fcmacs_libregnum_editor_node_color,
       Scmacs_libregnum_editor_node_color, 2, 2, 0,
       doc: /* Return NODE-ID's material color in BUFFER as a list (R G B A)
of floats, or nil if the node has no material.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  float fr = 0, fg = 0, fb = 0, fa = 1;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!cmacs_libregnum_render_ctx_editor_node_color
        (ctx, (gint) XFIXNUM (node_id), &fr, &fg, &fb, &fa))
    return Qnil;
  return list4 (make_float (fr), make_float (fg),
                make_float (fb), make_float (fa));
}

DEFUN ("cmacs-libregnum-editor-set-roughness",
       Fcmacs_libregnum_editor_set_roughness,
       Scmacs_libregnum_editor_set_roughness, 3, 3, 0,
       doc: /* Set the material roughness of NODE-ID in BUFFER to V (0..1).
Returns t on success, nil if NODE-ID has no visual.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object v)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *view = cmacs_libregnum_view_for_buffer (buffer);
  if (!view) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (view);
  gboolean ok = cmacs_libregnum_render_ctx_editor_set_roughness
                  (ctx, (gint) XFIXNUM (node_id),
                   (float) cmacs_libregnum__to_double (v));
  if (ok) cmacs_libregnum_view_request_redraw (view);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-set-metallic",
       Fcmacs_libregnum_editor_set_metallic,
       Scmacs_libregnum_editor_set_metallic, 3, 3, 0,
       doc: /* Set the material metallic of NODE-ID in BUFFER to V (0..1).
Returns t on success, nil if NODE-ID has no visual.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object v)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *view = cmacs_libregnum_view_for_buffer (buffer);
  if (!view) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (view);
  gboolean ok = cmacs_libregnum_render_ctx_editor_set_metallic
                  (ctx, (gint) XFIXNUM (node_id),
                   (float) cmacs_libregnum__to_double (v));
  if (ok) cmacs_libregnum_view_request_redraw (view);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-duplicate-node",
       Fcmacs_libregnum_editor_duplicate_node,
       Scmacs_libregnum_editor_duplicate_node, 2, 2, 0,
       doc: /* Clone NODE-ID in BUFFER under its current parent.
Returns the new node's scene id (integer), or nil on failure.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  gint nid;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  nid = cmacs_libregnum_render_ctx_editor_duplicate_node
          (ctx, (gint) XFIXNUM (node_id));
  cmacs_libregnum_view_request_redraw (v);
  return (nid >= 0) ? make_fixnum (nid) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-parent",
       Fcmacs_libregnum_editor_node_parent,
       Scmacs_libregnum_editor_node_parent, 2, 2, 0,
       doc: /* Return the editor id of NODE-ID's parent in BUFFER.
Returns an integer, or nil if NODE-ID is a root-level node or unknown.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  gint pid;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  pid = cmacs_libregnum_render_ctx_editor_node_parent
          (ctx, (gint) XFIXNUM (node_id));
  return (pid >= 0) ? make_fixnum (pid) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-add-empty",
       Fcmacs_libregnum_editor_add_empty,
       Scmacs_libregnum_editor_add_empty, 2, 3, 0,
       doc: /* Add an empty group node named NAME to BUFFER's level.
PARENT-ID is the parent node id; -1 or nil means the level root.
Returns the new node's scene id, or nil.  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object parent_id)
{
  gint pid, nid;
  CHECK_BUFFER (buffer);
  CHECK_STRING (name);
  pid = FIXNUMP (parent_id) ? (gint) XFIXNUM (parent_id) : -1;
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  nid = cmacs_libregnum_render_ctx_editor_add_empty
          (ctx, SSDATA (name), pid);
  cmacs_libregnum_view_request_redraw (v);
  return (nid >= 0) ? make_fixnum (nid) : Qnil;
}

DEFUN ("cmacs-libregnum-editor-node-scripts",
       Fcmacs_libregnum_editor_node_scripts,
       Scmacs_libregnum_editor_node_scripts, 2, 2, 0,
       doc: /* Return a list of script bindings on NODE-ID in BUFFER.
Each element is a plist
  (:language LANG-INT :path PATH-STRING :enabled BOOL)
in binding order.  Returns nil if NODE-ID is invalid or has no scripts.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  GPtrArray  *scripts;
  Lisp_Object result = Qnil;
  guint       i;
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  scripts = cmacs_libregnum_render_ctx_editor_node_scripts
              (ctx, (gint) XFIXNUM (node_id));
  if (!scripts) return Qnil;
  for (i = scripts->len; i-- > 0; )
    {
      LrgScriptBinding *b =
        (LrgScriptBinding *) g_ptr_array_index (scripts, i);
      const char *path = lrg_script_binding_get_script (b);
      int lang = (int) lrg_script_binding_get_language (b);
      gboolean enabled = lrg_script_binding_get_enabled (b);
      result = Fcons (CALLN (Flist,
                             intern (":language"), make_fixnum (lang),
                             intern (":path"),
                             path ? build_string (path) : Qnil,
                             intern (":enabled"), enabled ? Qt : Qnil),
                      result);
    }
  return result;
}

DEFUN ("cmacs-libregnum-editor-detach-script",
       Fcmacs_libregnum_editor_detach_script,
       Scmacs_libregnum_editor_detach_script, 3, 3, 0,
       doc: /* Remove the INDEX-th script binding (0-based) from NODE-ID
in BUFFER.  Returns t on success, nil if NODE-ID or INDEX is invalid.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object index)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_FIXNUM (index);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_detach_script
                  (ctx, (gint) XFIXNUM (node_id), (gint) XFIXNUM (index));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-set-node-asset",
       Fcmacs_libregnum_editor_set_node_asset,
       Scmacs_libregnum_editor_set_node_asset, 3, 3, 0,
       doc: /* Set NODE-ID's visual asset path in BUFFER to ASSET (a string).
Calls lrg_node_visual_set_asset + re-bakes.  Returns t on success.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object asset)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CHECK_STRING (asset);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_set_node_asset
                  (ctx, (gint) XFIXNUM (node_id), SSDATA (asset));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-unpack-prefab",
       Fcmacs_libregnum_editor_unpack_prefab,
       Scmacs_libregnum_editor_unpack_prefab, 2, 2, 0,
       doc: /* Strip the visual from NODE-ID in BUFFER, leaving a plain group.
This detaches the node from its prefab, making it directly editable.
Returns t on success, nil if NODE-ID is unknown.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_unpack_prefab
                  (ctx, (gint) XFIXNUM (node_id));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

/* ── Multi-select ──────────────────────────────────────────────────── */

DEFUN ("cmacs-libregnum-editor-select-add",
       Fcmacs_libregnum_editor_select_add,
       Scmacs_libregnum_editor_select_add, 2, 2, 0,
       doc: /* Add NODE-ID to the multi-selection in BUFFER (additive).
Returns t on success, nil if NODE-ID is unknown.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_select_add
                  (ctx, (gint) XFIXNUM (node_id));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-select-remove",
       Fcmacs_libregnum_editor_select_remove,
       Scmacs_libregnum_editor_select_remove, 2, 2, 0,
       doc: /* Remove NODE-ID from the multi-selection in BUFFER.
Returns t on success, nil if NODE-ID is unknown.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_select_remove
                  (ctx, (gint) XFIXNUM (node_id));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-select-clear",
       Fcmacs_libregnum_editor_select_clear,
       Scmacs_libregnum_editor_select_clear, 1, 1, 0,
       doc: /* Clear the entire multi-selection in BUFFER.  Always returns t.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qt;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_select_clear (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-selected-ids",
       Fcmacs_libregnum_editor_selected_ids,
       Scmacs_libregnum_editor_selected_ids, 1, 1, 0,
       doc: /* Return the list of all selected node ids in BUFFER.
Returns a list of integers (may be empty), or nil if BUFFER has no view.  */)
  (Lisp_Object buffer)
{
  GArray     *ids;
  Lisp_Object result = Qnil;
  guint       i;
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  ids = cmacs_libregnum_render_ctx_editor_selected_ids (ctx);
  for (i = ids->len; i-- > 0; )
    result = Fcons (make_fixnum (g_array_index (ids, gint, i)), result);
  g_array_unref (ids);
  return result;
}

/* ── Feature 1: real-time scene shading ─────────────────────────────── */

DEFUN ("cmacs-libregnum-editor-set-shading",
       Fcmacs_libregnum_editor_set_shading,
       Scmacs_libregnum_editor_set_shading, 2, 2, 0,
       doc: /* Enable or disable Blinn-Phong shading in BUFFER's editor.
ON non-nil enables lit rendering (up to 4 LIGHT nodes drive the shader);
nil disables it and reverts to the default unlit material.
Returns t on success, nil if BUFFER has no editor view.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_shading (ctx, !NILP (on));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-shading-p",
       Fcmacs_libregnum_editor_shading_p,
       Scmacs_libregnum_editor_shading_p, 1, 1, 0,
       doc: /* Return t if BUFFER's editor has shading enabled, nil otherwise.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  return cmacs_libregnum_render_ctx_editor_shading_p (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-set-headlight",
       Fcmacs_libregnum_editor_set_headlight,
       Scmacs_libregnum_editor_set_headlight, 2, 2, 0,
       doc: /* Enable or disable the camera-anchored key+fill light rig in
BUFFER's editor.  With ON non-nil, a model-only scene (no LIGHT nodes) is
lit by surface orientation -- the fix for a flat, washed-out preview.
Needs shading on (see `cmacs-libregnum-editor-set-shading') to take
effect.  Returns t on success.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_headlight (ctx, !NILP (on));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-set-edges",
       Fcmacs_libregnum_editor_set_edges,
       Scmacs_libregnum_editor_set_edges, 2, 2, 0,
       doc: /* Enable or disable the dark edge overlay (shaded-with-edges)
on BUFFER's editor models.  Returns t on success.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_set_edges (ctx, !NILP (on));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

/* ── Feature 2: look-through camera ─────────────────────────────────── */

DEFUN ("cmacs-libregnum-editor-look-through",
       Fcmacs_libregnum_editor_look_through,
       Scmacs_libregnum_editor_look_through, 2, 2, 0,
       doc: /* Drive BUFFER's viewport from the CAMERA node at ID.
Returns t if ID is a valid CAMERA node; nil otherwise.
While active, orbit/pan/zoom/focus are suppressed.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gboolean ok = cmacs_libregnum_render_ctx_editor_look_through
                  (ctx, (gint) XFIXNUM (id));
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-editor-look-through-off",
       Fcmacs_libregnum_editor_look_through_off,
       Scmacs_libregnum_editor_look_through_off, 1, 1, 0,
       doc: /* Cancel look-through in BUFFER and restore the orbit camera.
Always returns t.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qt;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_editor_look_through_off (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-editor-look-through-p",
       Fcmacs_libregnum_editor_look_through_p,
       Scmacs_libregnum_editor_look_through_p, 1, 1, 0,
       doc: /* Return the look-through node id if active in BUFFER, nil otherwise.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gint result = cmacs_libregnum_render_ctx_editor_look_through_p (ctx);
  return (result >= 0) ? make_fixnum (result) : Qnil;
}

/* ── Feature 3: per-node visual param read-back ─────────────────────── */

DEFUN ("cmacs-libregnum-editor-get-visual-param",
       Fcmacs_libregnum_editor_get_visual_param,
       Scmacs_libregnum_editor_get_visual_param, 4, 4, 0,
       doc: /* Return the named visual param of node ID in BUFFER as a float.
NAME is the param name string (e.g. \"wireframe\", \"fov\").
DEFAULT is returned when ID is invalid or the param is not set.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object name, Lisp_Object defval)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (id);
  CHECK_STRING (name);
  CHECK_NUMBER (defval);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return defval;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  double result = cmacs_libregnum_render_ctx_editor_get_visual_param
                    (ctx, (gint) XFIXNUM (id),
                     SSDATA (name),
                     XFLOATINT (defval));
  return make_float (result);
}

extern Lisp_Object *cmacs_libregnum__buffers_root  (void);
extern Lisp_Object *cmacs_libregnum__payloads_root (void);

void syms_of_cmacs_libregnum_defuns (void);
void
syms_of_cmacs_libregnum_defuns (void)
{
  DEFSYM (Qcmacs_libregnum_error, "cmacs-libregnum-error");
  /* Per-node label policy symbols (cmacs-libregnum-set-node-label-mode).
     Namespaced C names because `never'/`always'/`hover'/`selected' are
     far too generic to claim as global DEFSYMs. */
  DEFSYM (Qcmacs_label_never, "never");
  DEFSYM (Qcmacs_label_selected, "selected");
  DEFSYM (Qcmacs_label_hover, "hover");
  DEFSYM (Qcmacs_label_always, "always");
  DEFSYM (Qcmacs_sel_halo, "halo");
  DEFSYM (Qcmacs_bg_solid, "solid");
  DEFSYM (Qcmacs_bg_gradient, "gradient");
  DEFSYM (Qcmacs_bg_starfield, "starfield");
  DEFSYM (Qcmacs_bg_nebula, "nebula");
  /* NOT DEFSYM'd here: `image' is xdisp.c's Qimage and `none' is
     frame.c's Qnone.  DEFSYM creates and interns a NEW symbol, so a
     second DEFSYM of an existing name puts two distinct symbols with
     the same name in the obarray -- and then `EQ' against the other
     one silently fails everywhere.  Doing it to "image" stops every
     `(image ...)' display spec from matching in xdisp.c, which shows up
     as images not rendering and their raw data leaking out as text. */
  Fput (Qcmacs_libregnum_error, Qerror_conditions,
        list2 (Qcmacs_libregnum_error, Qerror));
  Fput (Qcmacs_libregnum_error, Qerror_message,
        build_string ("CMacs libregnum error"));

  /* The view registry's Lisp hash tables (lazy-instantiated on
   * first use) need their static slots GC-rooted. */
  *cmacs_libregnum__buffers_root  () = Qnil;
  *cmacs_libregnum__payloads_root () = Qnil;
  staticpro (cmacs_libregnum__buffers_root  ());
  staticpro (cmacs_libregnum__payloads_root ());

  defsubr (&Scmacs_libregnum_supported_p);
  defsubr (&Scmacs_libregnum_attach);
  defsubr (&Scmacs_libregnum_detach);
  defsubr (&Scmacs_libregnum_attached_p);
  defsubr (&Scmacs_libregnum_resize);
  defsubr (&Scmacs_libregnum_view_size);
  defsubr (&Scmacs_libregnum_redraw);
  defsubr (&Scmacs_libregnum_image_enter);
  defsubr (&Scmacs_libregnum_image_p);
  defsubr (&Scmacs_libregnum_image_upload_rgba);
  defsubr (&Scmacs_libregnum_image_refresh);
  defsubr (&Scmacs_libregnum_image_set_view);
  defsubr (&Scmacs_libregnum_image_view);
  defsubr (&Scmacs_libregnum_image_zoom_at);
  defsubr (&Scmacs_libregnum_image_fit);
  defsubr (&Scmacs_libregnum_image_view_to_doc);
  defsubr (&Scmacs_libregnum_image_set_checker);
  defsubr (&Scmacs_libregnum_image_set_grid);
  defsubr (&Scmacs_libregnum_image_set_cursor);
  defsubr (&Scmacs_libregnum_image_set_marquee);
  defsubr (&Scmacs_libregnum_image_timeline);
  defsubr (&Scmacs_libregnum_image_set_label_font);
  defsubr (&Scmacs_libregnum_image_timeline_hit);
  defsubr (&Scmacs_libregnum_set_animated);
  defsubr (&Scmacs_libregnum_animated_p);
  defsubr (&Scmacs_libregnum_tree_nodes);
  defsubr (&Scmacs_libregnum_set_selection);
  defsubr (&Scmacs_libregnum_set_node_label_mode);
  defsubr (&Scmacs_libregnum_set_inscene_labels);
  defsubr (&Scmacs_libregnum_set_label_font);
  defsubr (&Scmacs_libregnum_set_label_style);
  defsubr (&Scmacs_libregnum_set_label_decor);
  defsubr (&Scmacs_libregnum_set_selection_style);
  defsubr (&Scmacs_libregnum_set_focus_policy);
  defsubr (&Scmacs_libregnum_set_background);
  defsubr (&Scmacs_libregnum_particles_enable);
  defsubr (&Scmacs_libregnum_particles_clear);
  defsubr (&Scmacs_libregnum_particles_emitter);
  defsubr (&Scmacs_libregnum_particles_burst);
  defsubr (&Scmacs_libregnum_particles_count);
  defsubr (&Scmacs_libregnum_pan);
  defsubr (&Scmacs_libregnum_set_right_drag_pans);
  defsubr (&Scmacs_libregnum_set_wheel_up_zooms_in);
  defsubr (&Scmacs_libregnum_orbit);
  defsubr (&Scmacs_libregnum_set_orbit_locked);
  defsubr (&Scmacs_libregnum_ink_bbox);
  defsubr (&Scmacs_libregnum_nearest_in_direction);
  defsubr (&Scmacs_libregnum_node_onscreen_p);
  defsubr (&Scmacs_libregnum_set_match_set);
  defsubr (&Scmacs_libregnum_set_node_flags);
  defsubr (&Scmacs_libregnum_clear_node_flags);
  defsubr (&Scmacs_libregnum_node_flags);
  defsubr (&Scmacs_libregnum_build_tree);
  defsubr (&Scmacs_libregnum_build_gobject);
  defsubr (&Scmacs_libregnum_build_mindmap);
  defsubr (&Scmacs_libregnum_camera_state);
  defsubr (&Scmacs_libregnum_set_camera);
  defsubr (&Scmacs_libregnum_load_game);
  defsubr (&Scmacs_libregnum_unload_game);
  defsubr (&Scmacs_libregnum_game_loaded_p);
  defsubr (&Scmacs_libregnum_game_key);

  defsubr (&Scmacs_libregnum_editor_new);
  defsubr (&Scmacs_libregnum_editor_open);
  defsubr (&Scmacs_libregnum_editor_save);
  defsubr (&Scmacs_libregnum_editor_active_p);
  defsubr (&Scmacs_libregnum_editor_add_primitive);
  defsubr (&Scmacs_libregnum_editor_delete);
  defsubr (&Scmacs_libregnum_editor_select);
  defsubr (&Scmacs_libregnum_editor_set_position);
  defsubr (&Scmacs_libregnum_editor_undo);
  defsubr (&Scmacs_libregnum_editor_redo);
  defsubr (&Scmacs_libregnum_editor_refresh);
#ifdef HAVE_CMACS_CAD
  defsubr (&Scmacs_libregnum_cad_invalidate);
  defsubr (&Scmacs_libregnum_cad_set_source);
#endif
  defsubr (&Scmacs_libregnum_editor_can_undo_p);
  defsubr (&Scmacs_libregnum_editor_node_guid);
  defsubr (&Scmacs_libregnum_editor_node_location);
  defsubr (&Scmacs_libregnum_editor_selected_id);
  defsubr (&Scmacs_libregnum_editor_set_snap);
  defsubr (&Scmacs_libregnum_editor_focus);
  defsubr (&Scmacs_libregnum_editor_drag_begin);
  defsubr (&Scmacs_libregnum_editor_drag_update);
  defsubr (&Scmacs_libregnum_editor_drag_end);
  defsubr (&Scmacs_libregnum_editor_node_rotation);
  defsubr (&Scmacs_libregnum_editor_node_scale);
  defsubr (&Scmacs_libregnum_editor_set_rotation);
  defsubr (&Scmacs_libregnum_editor_set_scale);
  defsubr (&Scmacs_libregnum_editor_reparent);
  defsubr (&Scmacs_libregnum_editor_add_visual);
  defsubr (&Scmacs_libregnum_editor_attach_script);
  defsubr (&Scmacs_libregnum_editor_node_script_count);
  defsubr (&Scmacs_libregnum_editor_play);
  defsubr (&Scmacs_libregnum_editor_stop);
  defsubr (&Scmacs_libregnum_editor_playing_p);
  defsubr (&Scmacs_libregnum_editor_play_tick);
  defsubr (&Scmacs_libregnum_editor_set_view_2d);
  defsubr (&Scmacs_libregnum_editor_view_2d_p);
  defsubr (&Scmacs_libregnum_editor_set_armed);
  defsubr (&Scmacs_libregnum_editor_screen_to_ground);
  defsubr (&Scmacs_libregnum_editor_tilemap_config);
  defsubr (&Scmacs_libregnum_editor_tilemap_set_tile);
  defsubr (&Scmacs_libregnum_editor_tilemap_info);
  defsubr (&Scmacs_libregnum_editor_node_object);
  defsubr (&Scmacs_libregnum_editor_save_prefab);
  defsubr (&Scmacs_libregnum_editor_instantiate_prefab);
  defsubr (&Scmacs_libregnum_editor_import_scene);
  defsubr (&Scmacs_libregnum_scripting_languages);
  defsubr (&Scmacs_libregnum_project_create);
  defsubr (&Scmacs_libregnum_editor_open_project);
  defsubr (&Scmacs_libregnum_assetdb_scan);
  defsubr (&Scmacs_libregnum_editor_set_visual_param);
  defsubr (&Scmacs_libregnum_editor_set_visual_param_undoable);
  defsubr (&Scmacs_libregnum_editor_node_asset);
  defsubr (&Scmacs_libregnum_editor_node_kind);
  defsubr (&Scmacs_libregnum_editor_node_primitive);
  defsubr (&Scmacs_libregnum_editor_set_name);
  defsubr (&Scmacs_libregnum_set_mouse_capture);
  defsubr (&Scmacs_libregnum_project);
  defsubr (&Scmacs_libregnum_editor_set_tool);
  defsubr (&Scmacs_libregnum_editor_get_tool);
  defsubr (&Scmacs_libregnum_editor_gizmo_begin);
  defsubr (&Scmacs_libregnum_editor_gizmo_drag);
  defsubr (&Scmacs_libregnum_editor_gizmo_end);
  defsubr (&Scmacs_libregnum_snapshot);

  /* Context-menu / authoring primitives. */
  defsubr (&Scmacs_libregnum_editor_set_color);
  defsubr (&Scmacs_libregnum_editor_node_color);
  defsubr (&Scmacs_libregnum_editor_set_roughness);
  defsubr (&Scmacs_libregnum_editor_set_metallic);
  defsubr (&Scmacs_libregnum_editor_duplicate_node);
  defsubr (&Scmacs_libregnum_editor_node_parent);
  defsubr (&Scmacs_libregnum_editor_add_empty);
  defsubr (&Scmacs_libregnum_editor_node_scripts);
  defsubr (&Scmacs_libregnum_editor_detach_script);
  defsubr (&Scmacs_libregnum_editor_set_node_asset);
  defsubr (&Scmacs_libregnum_editor_unpack_prefab);
  defsubr (&Scmacs_libregnum_editor_select_add);
  defsubr (&Scmacs_libregnum_editor_select_remove);
  defsubr (&Scmacs_libregnum_editor_select_clear);
  defsubr (&Scmacs_libregnum_editor_selected_ids);

  /* Render features: shading, look-through, visual param. */
  defsubr (&Scmacs_libregnum_editor_set_shading);
  defsubr (&Scmacs_libregnum_editor_shading_p);
  defsubr (&Scmacs_libregnum_editor_set_headlight);
  defsubr (&Scmacs_libregnum_editor_set_edges);
  defsubr (&Scmacs_libregnum_editor_look_through);
  defsubr (&Scmacs_libregnum_editor_look_through_off);
  defsubr (&Scmacs_libregnum_editor_look_through_p);
  defsubr (&Scmacs_libregnum_editor_get_visual_param);
}

#endif /* HAVE_CMACS_LIBREGNUM */
