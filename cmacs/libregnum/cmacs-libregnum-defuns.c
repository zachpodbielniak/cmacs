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
extract_float (Lisp_Object obj)
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
  double px = extract_float (XCAR (position));
  Lisp_Object py_c = XCDR (position);
  double py = CONSP (py_c) ? extract_float (XCAR (py_c)) : 0.0;
  Lisp_Object pz_c = CONSP (py_c) ? XCDR (py_c) : Qnil;
  double pz = CONSP (pz_c) ? extract_float (XCAR (pz_c)) : 0.0;
  double tx = extract_float (XCAR (target));
  Lisp_Object ty_c = XCDR (target);
  double ty = CONSP (ty_c) ? extract_float (XCAR (ty_c)) : 0.0;
  Lisp_Object tz_c = CONSP (ty_c) ? XCDR (ty_c) : Qnil;
  double tz = CONSP (tz_c) ? extract_float (XCAR (tz_c)) : 0.0;
  double fov_d = extract_float (fov);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_set_camera_state (ctx,
                                                px, py, pz,
                                                tx, ty, tz, fov_d);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

extern Lisp_Object *cmacs_libregnum__buffers_root  (void);
extern Lisp_Object *cmacs_libregnum__payloads_root (void);

void syms_of_cmacs_libregnum_defuns (void);
void
syms_of_cmacs_libregnum_defuns (void)
{
  DEFSYM (Qcmacs_libregnum_error, "cmacs-libregnum-error");
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
  defsubr (&Scmacs_libregnum_redraw);
  defsubr (&Scmacs_libregnum_build_tree);
  defsubr (&Scmacs_libregnum_build_gobject);
  defsubr (&Scmacs_libregnum_build_mindmap);
  defsubr (&Scmacs_libregnum_camera_state);
  defsubr (&Scmacs_libregnum_set_camera);
}

#endif /* HAVE_CMACS_LIBREGNUM */
