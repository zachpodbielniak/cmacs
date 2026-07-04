/* cmacs-gnuseye-overlay.c --- Elisp boundary for the weather overlays.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DEFUNs driving the draped raster weather channels (radar, clouds, ...)
 * implemented by cmacs-gnuseye-overlay-render.c, plus the live base-
 * texture swap ("Earth today").  Never includes <libregnum.h> -- it talks
 * to the render half through the plain-C API in cmacs-gnuseye-overlay.h,
 * exactly like cmacs-gnuseye-defuns.c (the firewall in cmacs-gnuseye.h).
 *
 * Everything here runs in DEFUN context, i.e. on the main thread where
 * the shared raylib GL context is current -- the contract every texture
 * upload below relies on.  NOTE: the overlay shells follow the globe's
 * background spin; weather mode should keep the spin at 0 or markers
 * (which do not spin) will misregister against the draped rasters. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "cmacs-gnuseye.h"
#include "cmacs-gnuseye-globe.h"
#include "cmacs-gnuseye-overlay.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"

/* Cached keyword symbols for the compose OPTS plist (set in syms_of). */
static Lisp_Object QCwx_canvas_width, QCwx_canvas_height, QCwx_projection,
  QCwx_luma_alpha, QCwx_tint, QCwx_show, Qwx_mercator;

/* BUFFER's render ctx, or NULL when no view is attached (DEFUNs then
 * return nil, the defuns.c convention for optional visuals). */
static CmacsLibregnumRenderCtx *
wx_ctx (Lisp_Object buffer, CmacsLibregnumView **vout)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (vout) *vout = v;
  return v ? cmacs_libregnum_view_get_render_ctx (v) : NULL;
}

/* Channel NAME symbol -> encoded C string (kept alive via *KEEP). */
static const char *
wx_name (Lisp_Object name, Lisp_Object *keep)
{
  CHECK_SYMBOL (name);
  *keep = ENCODE_UTF_8 (SYMBOL_NAME (name));
  return SSDATA (*keep);
}

static int
wx_num (Lisp_Object v, int def)
{
  if (FIXNUMP (v)) return (int) XFIXNUM (v);
  if (FLOATP (v)) return (int) XFLOAT_DATA (v);
  return def;
}

DEFUN ("cmacs-gnuseye-overlay-ensure", Fcmacs_gnuseye_overlay_ensure,
       Scmacs_gnuseye_overlay_ensure, 2, 6, 0,
       doc: /* Create weather overlay channel NAME on BUFFER's globe.
NAME is a symbol (e.g. `radar', `clouds').  A channel is a cache of
draped raster frames that are composited (in RADIUS-SCALE order, higher
over lower) onto the globe's base texture -- so the weather picks up the
day/night terminator, follows the globe's spin, and registers exactly
with the markers.  TEX-W and TEX-H are accepted for compatibility but
ignored (frames follow the globe texture's dimensions).  CACHE-BYTES
caps the channel's composed-frame cache (default 64 MiB).  Idempotent.
Returns t, or nil when no globe is attached or the globe is in flat-map
mode (draped rasters are globe-only).  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object radius_scale,
   Lisp_Object tex_w, Lisp_Object tex_h, Lisp_Object cache_bytes)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  const char *nm = wx_name (name, &keep);
  double rs = NILP (radius_scale) ? 0.0 : XFLOATINT (radius_scale);
  gint64 cap = NILP (cache_bytes) ? 0 : (gint64) XFLOATINT (cache_bytes);
  if (!cmacs_gnuseye_overlay_ensure (ctx, nm, rs, wx_num (tex_w, 0),
                                     wx_num (tex_h, 0), cap))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-overlay-p", Fcmacs_gnuseye_overlay_p,
       Scmacs_gnuseye_overlay_p, 2, 2, 0,
       doc: /* Return t when overlay channel NAME exists on BUFFER's globe.  */)
  (Lisp_Object buffer, Lisp_Object name)
{
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, NULL);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  return cmacs_gnuseye_overlay_exists_p (ctx, wx_name (name, &keep))
    ? Qt : Qnil;
}

DEFUN ("cmacs-gnuseye-overlay-compose-frame",
       Fcmacs_gnuseye_overlay_compose_frame,
       Scmacs_gnuseye_overlay_compose_frame, 4, 5, 0,
       doc: /* Compose (and cache) one frame for overlay channel NAME on BUFFER.
TAG is the frame's cache key (e.g. a radar timestamp).  TILES is a list of
placements (FILE DST-X DST-Y [DST-W DST-H]): each image FILE (PNG or JPEG,
decoded via gdk-pixbuf) is pasted onto the compose canvas at pixel
DST-X,DST-Y, nearest-scaled to DST-W x DST-H when given.  Missing or
undecodable tiles are skipped (that region stays transparent).

OPTS is a plist:
  :canvas-width, :canvas-height  compose canvas size (default 1024 x 512)
  :projection   `mercator' when the canvas is web-mercator (rows spanning
                lat +-85.05, reprojected to equirect; polar bands stay
                transparent); anything else means equirect (+-90)
  :luma-alpha   map luminance to opacity for opaque grayscale imagery
                (IR clouds): t for defaults, or a cons (LO . GAIN) in 0..1
                luma units -- alpha = clamp((luma - LO) * GAIN)
  :tint         0xRRGGBBAA recolour applied by :luma-alpha (default white)
  :show         non-nil to also upload the frame and make it current

The canvas is warped through the globe's mesh-UV transform, so the drape
registers exactly with the lat/lon marker convention.  Returns the number
of tiles decoded, or nil when nothing was composed.  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object tag,
   Lisp_Object tiles, Lisp_Object opts)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  const char *nm = wx_name (name, &keep);
  CHECK_STRING (tag);
  Lisp_Object tag_enc = ENCODE_UTF_8 (tag);

  /* Copy tile placements out of Lisp data up front (paths g_strdup'd), so
   * the compose loop below runs with no Lisp allocation at all. */
  GArray *arr = g_array_new (FALSE, TRUE, sizeof (CmacsGnuseyeTilePlace));
  GPtrArray *paths = g_ptr_array_new_with_free_func (g_free);
  for (Lisp_Object tail = tiles; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object item = XCAR (tail);
      if (!CONSP (item) || !STRINGP (XCAR (item))) continue;
      Lisp_Object file = ENCODE_FILE (XCAR (item));
      Lisp_Object rest = XCDR (item);
      CmacsGnuseyeTilePlace tp = { 0 };
      gchar *p = g_strdup (SSDATA (file));
      g_ptr_array_add (paths, p);
      tp.path = p;
      tp.dst_x = CONSP (rest) ? wx_num (XCAR (rest), 0) : 0;
      rest = CONSP (rest) ? XCDR (rest) : Qnil;
      tp.dst_y = CONSP (rest) ? wx_num (XCAR (rest), 0) : 0;
      rest = CONSP (rest) ? XCDR (rest) : Qnil;
      tp.dst_w = CONSP (rest) ? wx_num (XCAR (rest), 0) : 0;
      rest = CONSP (rest) ? XCDR (rest) : Qnil;
      tp.dst_h = CONSP (rest) ? wx_num (XCAR (rest), 0) : 0;
      g_array_append_val (arr, tp);
    }

  int cw = wx_num (plist_get (opts, QCwx_canvas_width), 1024);
  int ch = wx_num (plist_get (opts, QCwx_canvas_height), 512);
  int proj = EQ (plist_get (opts, QCwx_projection), Qwx_mercator)
    ? CMACS_GNUSEYE_OVERLAY_MERCATOR : CMACS_GNUSEYE_OVERLAY_EQUIRECT;
  Lisp_Object la = plist_get (opts, QCwx_luma_alpha);
  double luma_lo = -1.0, luma_gain = 0.0;
  if (CONSP (la))
    {
      luma_lo = XFLOATINT (XCAR (la));
      luma_gain = XFLOATINT (XCDR (la));
    }
  else if (!NILP (la))
    {
      luma_lo = 0.20;
      luma_gain = 2.5;
    }
  Lisp_Object tint = plist_get (opts, QCwx_tint);
  guint32 tint_rgba = FIXNUMP (tint) ? (guint32) XFIXNUM (tint) : 0xffffffffu;
  gboolean show = !NILP (plist_get (opts, QCwx_show));

  int decoded = cmacs_gnuseye_overlay_compose_frame
    (ctx, nm, SSDATA (tag_enc),
     (const CmacsGnuseyeTilePlace *) arr->data, (int) arr->len,
     cw, ch, proj, luma_lo, luma_gain, tint_rgba, show);

  g_array_free (arr, TRUE);
  g_ptr_array_unref (paths);
  if (decoded <= 0) return Qnil;
  if (show) cmacs_libregnum_view_request_redraw (v);
  return make_fixnum (decoded);
}

DEFUN ("cmacs-gnuseye-overlay-show-frame", Fcmacs_gnuseye_overlay_show_frame,
       Scmacs_gnuseye_overlay_show_frame, 3, 3, 0,
       doc: /* Display cached frame TAG on overlay channel NAME of BUFFER.
The cheap animation step: re-uploads an already-composed frame.  Returns
t after the upload, or nil when TAG is not cached (the caller composes it
once with `cmacs-gnuseye-overlay-compose-frame').  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object tag)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  const char *nm = wx_name (name, &keep);
  CHECK_STRING (tag);
  Lisp_Object tag_enc = ENCODE_UTF_8 (tag);
  if (!cmacs_gnuseye_overlay_show_frame (ctx, nm, SSDATA (tag_enc)))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-overlay-frames", Fcmacs_gnuseye_overlay_frames,
       Scmacs_gnuseye_overlay_frames, 2, 2, 0,
       doc: /* List overlay channel NAME's cached frame tags on BUFFER.
Most recently shown first.  nil when the channel does not exist.  */)
  (Lisp_Object buffer, Lisp_Object name)
{
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, NULL);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  char **tags = cmacs_gnuseye_overlay_frame_tags (ctx, wx_name (name, &keep));
  if (!tags) return Qnil;
  Lisp_Object res = Qnil;
  for (int i = 0; tags[i]; i++)
    res = Fcons (build_string (tags[i]), res);
  g_strfreev (tags);
  return Fnreverse (res);
}

DEFUN ("cmacs-gnuseye-overlay-set-alpha", Fcmacs_gnuseye_overlay_set_alpha,
       Scmacs_gnuseye_overlay_set_alpha, 3, 3, 0,
       doc: /* Set overlay channel NAME's opacity multiplier on BUFFER.
ALPHA is 0.0 (invisible) .. 1.0 (the frame's own alpha).  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object alpha)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  if (!cmacs_gnuseye_overlay_set_alpha (ctx, wx_name (name, &keep),
                                        XFLOATINT (alpha)))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-overlay-set-enabled",
       Fcmacs_gnuseye_overlay_set_enabled,
       Scmacs_gnuseye_overlay_set_enabled, 3, 3, 0,
       doc: /* Toggle overlay channel NAME on BUFFER without dropping its cache.
ENABLED nil hides the shell; non-nil shows it again.  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object enabled)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  if (!cmacs_gnuseye_overlay_set_enabled (ctx, wx_name (name, &keep),
                                          !NILP (enabled)))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-overlay-clear", Fcmacs_gnuseye_overlay_clear,
       Scmacs_gnuseye_overlay_clear, 1, 2, 0,
       doc: /* Drop overlay channel NAME (or all channels) from BUFFER's globe.
Releases the shell model, texture, and frame cache.  */)
  (Lisp_Object buffer, Lisp_Object name)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  Lisp_Object keep = Qnil;
  cmacs_gnuseye_overlay_clear (ctx, NILP (name) ? NULL
                                                : wx_name (name, &keep));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-set-base-texture", Fcmacs_gnuseye_set_base_texture,
       Scmacs_gnuseye_set_base_texture, 2, 2, 0,
       doc: /* Re-skin BUFFER's globe from equirectangular image PATH.
PATH may be PNG or JPEG (JPEG decodes via gdk-pixbuf) -- the "Earth
today" live swap for real daily satellite imagery.  Markers keep their
alignment (the image goes through the same mesh-UV warp as the default
texture).  Returns t, or nil when the image cannot be read or no globe
is attached.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = wx_ctx (buffer, &v);
  if (!ctx) return Qnil;
  CHECK_STRING (path);
  Lisp_Object enc = ENCODE_FILE (Fexpand_file_name (path, Qnil));
  if (!cmacs_gnuseye_globe_set_base_texture (ctx, SSDATA (enc)))
    return Qnil;
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

void
syms_of_cmacs_gnuseye_overlay (void)
{
  QCwx_canvas_width  = intern_c_string (":canvas-width");
  QCwx_canvas_height = intern_c_string (":canvas-height");
  QCwx_projection    = intern_c_string (":projection");
  QCwx_luma_alpha    = intern_c_string (":luma-alpha");
  QCwx_tint          = intern_c_string (":tint");
  QCwx_show          = intern_c_string (":show");
  Qwx_mercator       = intern_c_string ("mercator");
  staticpro (&QCwx_canvas_width);
  staticpro (&QCwx_canvas_height);
  staticpro (&QCwx_projection);
  staticpro (&QCwx_luma_alpha);
  staticpro (&QCwx_tint);
  staticpro (&QCwx_show);
  staticpro (&Qwx_mercator);

  defsubr (&Scmacs_gnuseye_overlay_ensure);
  defsubr (&Scmacs_gnuseye_overlay_p);
  defsubr (&Scmacs_gnuseye_overlay_compose_frame);
  defsubr (&Scmacs_gnuseye_overlay_show_frame);
  defsubr (&Scmacs_gnuseye_overlay_frames);
  defsubr (&Scmacs_gnuseye_overlay_set_alpha);
  defsubr (&Scmacs_gnuseye_overlay_set_enabled);
  defsubr (&Scmacs_gnuseye_overlay_clear);
  defsubr (&Scmacs_gnuseye_set_base_texture);
}

#endif /* HAVE_CMACS_GNUSEYE */
